/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/search.hpp>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/dictionary/detail/search.hpp>
#include <cudf/dictionary/detail/update_keys.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/search.hpp>
#include <cudf/table/row_operators.cuh>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/table_view.hpp>

#include <hash/unordered_multiset.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/binary_search.h>

namespace cudf {
namespace {
template <typename DataIterator,
          typename ValuesIterator,
          typename OutputIterator,
          typename Comparator>
void launch_search(DataIterator it_data,
                   ValuesIterator it_vals,
                   size_type data_size,
                   size_type values_size,
                   OutputIterator it_output,
                   Comparator comp,
                   bool find_first,
                   rmm::cuda_stream_view stream)
{
  if (find_first) {
    thrust::lower_bound(rmm::exec_policy(stream),
                        it_data,
                        it_data + data_size,
                        it_vals,
                        it_vals + values_size,
                        it_output,
                        comp);
  } else {
    thrust::upper_bound(rmm::exec_policy(stream),
                        it_data,
                        it_data + data_size,
                        it_vals,
                        it_vals + values_size,
                        it_output,
                        comp);
  }
}

std::unique_ptr<column> search_ordered(table_view const& t,
                                       table_view const& values,
                                       bool find_first,
                                       std::vector<order> const& column_order,
                                       std::vector<null_order> const& null_precedence,
                                       rmm::cuda_stream_view stream,
                                       rmm::mr::device_memory_resource* mr)
{
  CUDF_EXPECTS(
    column_order.empty() or static_cast<std::size_t>(t.num_columns()) == column_order.size(),
    "Mismatch between number of columns and column order.");
  CUDF_EXPECTS(
    null_precedence.empty() or static_cast<std::size_t>(t.num_columns()) == null_precedence.size(),
    "Mismatch between number of columns and null precedence.");

  // Allocate result column
  auto result = make_numeric_column(
    data_type{type_to_id<size_type>()}, values.num_rows(), mask_state::UNALLOCATED, stream, mr);
  auto const result_out = result->mutable_view().data<size_type>();

  // Handle empty inputs
  if (t.num_rows() == 0) {
    CUDA_TRY(cudaMemsetAsync(result_out, 0, values.num_rows() * sizeof(size_type), stream.value()));
    return result;
  }

  // This utility will ensure all corresponding dictionary columns have matching keys.
  // It will return any new dictionary columns created as well as updated table_views.
  auto const matched = dictionary::detail::match_dictionaries({t, values}, stream);

  // Prepare to flatten the structs column
  auto const has_null_elements   = has_nested_nulls(t) or has_nested_nulls(values);
  auto const flatten_nullability = has_null_elements
                                     ? structs::detail::column_nullability::FORCE
                                     : structs::detail::column_nullability::MATCH_INCOMING;

  // 0-table_view, 1-column_order, 2-null_precedence, 3-validity_columns
  auto const t_flattened = structs::detail::flatten_nested_columns(
    matched.second.front(), column_order, null_precedence, flatten_nullability);
  auto const values_flattened =
    structs::detail::flatten_nested_columns(matched.second.back(), {}, {}, flatten_nullability);

  auto const t_d      = table_device_view::create(t_flattened, stream);
  auto const values_d = table_device_view::create(values_flattened, stream);
  auto const& lhs     = find_first ? *t_d : *values_d;
  auto const& rhs     = find_first ? *values_d : *t_d;

  auto const& column_order_flattened    = t_flattened.orders();
  auto const& null_precedence_flattened = t_flattened.null_orders();
  auto const column_order_dv = detail::make_device_uvector_async(column_order_flattened, stream);
  auto const null_precedence_dv =
    detail::make_device_uvector_async(null_precedence_flattened, stream);

  auto const count_it = thrust::make_counting_iterator<size_type>(0);
  auto const comp     = row_lexicographic_comparator(nullate::DYNAMIC{has_null_elements},
                                                 lhs,
                                                 rhs,
                                                 column_order_dv.data(),
                                                 null_precedence_dv.data());
  launch_search(
    count_it, count_it, t.num_rows(), values.num_rows(), result_out, comp, find_first, stream);

  return result;
}

struct contains_scalar_dispatch {
  template <typename Element>
  bool operator()(column_view const& col, scalar const& value, rmm::cuda_stream_view stream)
  {
    CUDF_EXPECTS(col.type() == value.type(), "scalar and column types must match");

    using Type       = device_storage_type_t<Element>;
    using ScalarType = cudf::scalar_type_t<Element>;
    auto d_col       = column_device_view::create(col, stream);
    auto s           = static_cast<const ScalarType*>(&value);

    if (col.has_nulls()) {
      auto found_iter = thrust::find(rmm::exec_policy(stream),
                                     d_col->pair_begin<Type, true>(),
                                     d_col->pair_end<Type, true>(),
                                     thrust::make_pair(s->value(stream), true));

      return found_iter != d_col->pair_end<Type, true>();
    } else {
      auto found_iter = thrust::find(rmm::exec_policy(stream),  //
                                     d_col->begin<Type>(),
                                     d_col->end<Type>(),
                                     s->value(stream));

      return found_iter != d_col->end<Type>();
    }
  }
};

template <>
bool contains_scalar_dispatch::operator()<cudf::list_view>(column_view const&,
                                                           scalar const&,
                                                           rmm::cuda_stream_view)
{
  CUDF_FAIL("list_view type not supported yet");
}

template <>
bool contains_scalar_dispatch::operator()<cudf::struct_view>(column_view const& col,
                                                             scalar const& value,
                                                             rmm::cuda_stream_view stream)
{
  CUDF_EXPECTS(col.type() == value.type(), "scalar and column types must match");

  auto const scalar_table = static_cast<struct_scalar const*>(&value)->view();
  CUDF_EXPECTS(col.num_children() == scalar_table.num_columns(),
               "struct scalar and structs column must have the same number of children");
  for (size_type i = 0; i < col.num_children(); ++i) {
    CUDF_EXPECTS(col.child(i).type() == scalar_table.column(i).type(),
                 "scalar and column children types must match");
  }

  // Prepare to flatten the structs column and scalar.
  auto const has_null_elements =
    has_nested_nulls(table_view{std::vector<column_view>{col.child_begin(), col.child_end()}}) ||
    has_nested_nulls(scalar_table);
  auto const flatten_nullability = has_null_elements
                                     ? structs::detail::column_nullability::FORCE
                                     : structs::detail::column_nullability::MATCH_INCOMING;

  // Flatten the input structs column, only materialize the bitmask if there is null in the input.
  auto const col_flattened =
    structs::detail::flatten_nested_columns(table_view{{col}}, {}, {}, flatten_nullability);
  auto const val_flattened =
    structs::detail::flatten_nested_columns(scalar_table, {}, {}, flatten_nullability);

  // The struct scalar only contains the struct member columns.
  // Thus, if there is any null in the input, we must exclude the first column in the flattened
  // table of the input column from searching because that column is the materialized bitmask of
  // the input structs column.
  auto const col_flattened_content  = col_flattened.flattened_columns();
  auto const col_flattened_children = table_view{std::vector<column_view>{
    col_flattened_content.begin() + static_cast<size_type>(has_null_elements),
    col_flattened_content.end()}};

  auto const d_col_children_ptr = table_device_view::create(col_flattened_children, stream);
  auto const d_val_ptr          = table_device_view::create(val_flattened, stream);

  auto const start_iter = thrust::make_counting_iterator<size_type>(0);
  auto const end_iter   = start_iter + col.size();
  auto const comp       = row_equality_comparator(
    nullate::DYNAMIC{has_null_elements}, *d_col_children_ptr, *d_val_ptr, null_equality::EQUAL);
  auto const found_iter = thrust::find_if(
    rmm::exec_policy(stream), start_iter, end_iter, [comp] __device__(auto const idx) {
      return comp(idx, 0);  // compare col[idx] == val[0].
    });

  return found_iter != end_iter;
}

template <>
bool contains_scalar_dispatch::operator()<cudf::dictionary32>(column_view const& col,
                                                              scalar const& value,
                                                              rmm::cuda_stream_view stream)
{
  auto dict_col = cudf::dictionary_column_view(col);
  // first, find the value in the dictionary's key set
  auto index = cudf::dictionary::detail::get_index(dict_col, value, stream);
  // if found, check the index is actually in the indices column
  return index->is_valid(stream) ? cudf::type_dispatcher(dict_col.indices().type(),
                                                         contains_scalar_dispatch{},
                                                         dict_col.indices(),
                                                         *index,
                                                         stream)
                                 : false;
}

}  // namespace

namespace detail {
bool contains(column_view const& col, scalar const& value, rmm::cuda_stream_view stream)
{
  if (col.is_empty()) { return false; }
  if (not value.is_valid(stream)) { return col.has_nulls(); }

  return cudf::type_dispatcher(col.type(), contains_scalar_dispatch{}, col, value, stream);
}

struct multi_contains_dispatch {
  template <typename Element>
  std::unique_ptr<column> operator()(column_view const& haystack,
                                     column_view const& needles,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    std::unique_ptr<column> result = make_numeric_column(data_type{type_to_id<bool>()},
                                                         haystack.size(),
                                                         copy_bitmask(haystack),
                                                         haystack.null_count(),
                                                         stream,
                                                         mr);

    if (haystack.is_empty()) { return result; }

    mutable_column_view result_view = result.get()->mutable_view();

    if (needles.is_empty()) {
      thrust::fill(
        rmm::exec_policy(stream), result_view.begin<bool>(), result_view.end<bool>(), false);
      return result;
    }

    auto hash_set        = cudf::detail::unordered_multiset<Element>::create(needles, stream);
    auto device_hash_set = hash_set.to_device();

    auto d_haystack_ptr = column_device_view::create(haystack, stream);
    auto d_haystack     = *d_haystack_ptr;

    if (haystack.has_nulls()) {
      thrust::transform(rmm::exec_policy(stream),
                        thrust::make_counting_iterator<size_type>(0),
                        thrust::make_counting_iterator<size_type>(haystack.size()),
                        result_view.begin<bool>(),
                        [device_hash_set, d_haystack] __device__(size_t index) {
                          return d_haystack.is_null_nocheck(index) ||
                                 device_hash_set.contains(d_haystack.element<Element>(index));
                        });
    } else {
      thrust::transform(rmm::exec_policy(stream),
                        thrust::make_counting_iterator<size_type>(0),
                        thrust::make_counting_iterator<size_type>(haystack.size()),
                        result_view.begin<bool>(),
                        [device_hash_set, d_haystack] __device__(size_t index) {
                          return device_hash_set.contains(d_haystack.element<Element>(index));
                        });
    }

    return result;
  }
};

template <>
std::unique_ptr<column> multi_contains_dispatch::operator()<list_view>(
  column_view const&, column_view const&, rmm::cuda_stream_view, rmm::mr::device_memory_resource*)
{
  CUDF_FAIL("list_view type not supported");
}

template <>
std::unique_ptr<column> multi_contains_dispatch::operator()<struct_view>(
  column_view const&, column_view const&, rmm::cuda_stream_view, rmm::mr::device_memory_resource*)
{
  CUDF_FAIL("struct_view type not supported");
}

template <>
std::unique_ptr<column> multi_contains_dispatch::operator()<dictionary32>(
  column_view const& haystack_in,
  column_view const& needles_in,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  dictionary_column_view const haystack(haystack_in);
  dictionary_column_view const needles(needles_in);
  // first combine keys so both dictionaries have the same set
  auto haystack_matched    = dictionary::detail::add_keys(haystack, needles.keys(), stream);
  auto const haystack_view = dictionary_column_view(haystack_matched->view());
  auto needles_matched     = dictionary::detail::set_keys(needles, haystack_view.keys(), stream);
  auto const needles_view  = dictionary_column_view(needles_matched->view());

  // now just use the indices for the contains
  column_view const haystack_indices = haystack_view.get_indices_annotated();
  column_view const needles_indices  = needles_view.get_indices_annotated();
  return cudf::type_dispatcher(haystack_indices.type(),
                               multi_contains_dispatch{},
                               haystack_indices,
                               needles_indices,
                               stream,
                               mr);
}

std::unique_ptr<column> contains(column_view const& haystack,
                                 column_view const& needles,
                                 rmm::cuda_stream_view stream,
                                 rmm::mr::device_memory_resource* mr)
{
  CUDF_EXPECTS(haystack.type() == needles.type(), "DTYPE mismatch");

  return cudf::type_dispatcher(
    haystack.type(), multi_contains_dispatch{}, haystack, needles, stream, mr);
}

std::unique_ptr<column> lower_bound(table_view const& t,
                                    table_view const& values,
                                    std::vector<order> const& column_order,
                                    std::vector<null_order> const& null_precedence,
                                    rmm::cuda_stream_view stream,
                                    rmm::mr::device_memory_resource* mr)
{
  return search_ordered(t, values, true, column_order, null_precedence, stream, mr);
}

std::unique_ptr<column> upper_bound(table_view const& t,
                                    table_view const& values,
                                    std::vector<order> const& column_order,
                                    std::vector<null_order> const& null_precedence,
                                    rmm::cuda_stream_view stream,
                                    rmm::mr::device_memory_resource* mr)
{
  return search_ordered(t, values, false, column_order, null_precedence, stream, mr);
}

}  // namespace detail

// external APIs

std::unique_ptr<column> lower_bound(table_view const& t,
                                    table_view const& values,
                                    std::vector<order> const& column_order,
                                    std::vector<null_order> const& null_precedence,
                                    rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::lower_bound(
    t, values, column_order, null_precedence, rmm::cuda_stream_default, mr);
}

std::unique_ptr<column> upper_bound(table_view const& t,
                                    table_view const& values,
                                    std::vector<order> const& column_order,
                                    std::vector<null_order> const& null_precedence,
                                    rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::upper_bound(
    t, values, column_order, null_precedence, rmm::cuda_stream_default, mr);
}

bool contains(column_view const& col, scalar const& value)
{
  CUDF_FUNC_RANGE();
  return detail::contains(col, value, rmm::cuda_stream_default);
}

std::unique_ptr<column> contains(column_view const& haystack,
                                 column_view const& needles,
                                 rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::contains(haystack, needles, rmm::cuda_stream_default, mr);
}

}  // namespace cudf
