/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
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
#pragma once

#include <cudf/column/column.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>

namespace cudf {
namespace dictionary {
namespace detail {
/**
 * @copydoc cudf::dictionary::add_keys(dictionary_column_view const&,column_view
 * const&,mm::mr::device_memory_resource*)
 *
 * @param stream CUDA stream used for device memory operations and kernel launches.
 */
std::unique_ptr<column> add_keys(
  dictionary_column_view const& dictionary_column,
  column_view const& new_keys,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @copydoc cudf::dictionary::remove_keys(dictionary_column_view const&,column_view
 * const&,mm::mr::device_memory_resource*)
 *
 * @param stream CUDA stream used for device memory operations and kernel launches.
 */
std::unique_ptr<column> remove_keys(
  dictionary_column_view const& dictionary_column,
  column_view const& keys_to_remove,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @copydoc cudf::dictionary::remove_unused_keys(dictionary_column_view
 * const&,mm::mr::device_memory_resource*)
 *
 * @param stream CUDA stream used for device memory operations and kernel launches.
 */
std::unique_ptr<column> remove_unused_keys(
  dictionary_column_view const& dictionary_column,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @copydoc cudf::dictionary::set_keys(dictionary_column_view
 * const&,mm::mr::device_memory_resource*)
 *
 * @param stream CUDA stream used for device memory operations and kernel launches.
 */
std::unique_ptr<column> set_keys(
  dictionary_column_view const& dictionary_column,
  column_view const& keys,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @copydoc
 * cudf::dictionary::match_dictionaries(std::vector<cudf::dictionary_column_view>,mm::mr::device_memory_resource*)
 *
 * @param stream CUDA stream used for device memory operations and kernel launches.
 */
std::vector<std::unique_ptr<column>> match_dictionaries(
  cudf::host_span<dictionary_column_view const> input,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Create new dictionaries that have keys merged from dictionary columns
 * found in the provided tables.
 *
 * The result includes a vector of new dictionary columns along with a
 * vector of table_views with corresponding updated column_views.
 * And any column_views in the input tables that are not dictionary type
 * are simply copied.
 *
 * Merging the dictionary keys also adjusts the indices appropriately in the
 * output dictionary columns.
 *
 * Any null rows are left unchanged.
 *
 * @param input Vector of cudf::table_views that include dictionary columns to be matched.
 * @param stream CUDA stream used for device memory operations and kernel launches.
 * @param mr Device memory resource used to allocate the returned column's device memory.
 * @return New dictionary columns and updated cudf::table_views.
 */
std::pair<std::vector<std::unique_ptr<column>>, std::vector<table_view>> match_dictionaries(
  std::vector<table_view> tables,
  rmm::cuda_stream_view stream        = rmm::cuda_stream_default,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

}  // namespace detail
}  // namespace dictionary
}  // namespace cudf
