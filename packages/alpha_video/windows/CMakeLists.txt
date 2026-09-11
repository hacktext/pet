# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "alpha_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "alpha_video_plugin")

# Any new source files that you add to the plugin should be added here.
# FrameSource lives in native/frame_source/ (not here) so it can be unit-
# tested with the native ctest suite instead of only through the Flutter
# integration test; it's pulled in below via target_link_libraries against
# the frame_source target that native_build's add_subdirectory() provides.
list(APPEND PLUGIN_SOURCES
  "alpha_video_plugin.cpp"
  "alpha_video_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/alpha_video/alpha_video_plugin_c_api.h"
  "alpha_video_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# This is a separate CMake project from native/, so it does not inherit the
# /utf-8 flag set there. Without it MSVC parses non-ASCII sources (including
# Chinese comments pulled in via pet_matte headers) under the system codepage.
target_compile_options(${PLUGIN_NAME} PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)

# Pull in the native rendering core (pcmat / matte_core / mf_decode / pet_matte
# / frame_source) and link the pet_matte C ABI plus the frame_source library
# that this plugin bridges to Dart.
#
# Flutter builds plugins through a symlink at
# .../ephemeral/.plugin_symlinks/<plugin>, so CMAKE_CURRENT_SOURCE_DIR points
# through that symlink. get_filename_component(... REALPATH) on the combined
# "<symlink>/../../../native" path resolves lexically on Windows (it does not
# dereference the symlink), landing under ephemeral/ instead of the repo. So
# resolve CMAKE_CURRENT_SOURCE_DIR to its real location FIRST, then apply the
# "../../../native" traversal to that already-resolved path.
get_filename_component(AIPET_REPO_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(AIPET_NATIVE_DIR "${AIPET_REPO_WINDOWS_DIR}/../../../native" REALPATH)

# native/'s FetchContent pulls in GoogleTest, whose own install() rules
# default on. This build's CMAKE_INSTALL_PREFIX is a per-config Flutter
# generator expression ($<TARGET_FILE_DIR:...>) that only resolves correctly
# for install() calls whose own DESTINATION argument contains that same
# expression, as Flutter's do. GoogleTest's relative "DESTINATION include"
# instead gets prefixed with the literal, unresolved genex text, which is not
# a valid Windows path and breaks the INSTALL step. We only need GoogleTest
# linked into the native test binaries, never installed, so disable it here
# (native/CMakeLists.txt itself is unmodified: this only affects the copy
# fetched for this Flutter-embedded build).
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)

# EXCLUDE_FROM_ALL: native/'s six test executables (pcmat_tests,
# matte_core_tests, mf_decode_tests, pet_matte_tests, frame_source_tests,
# prepare_queue_tests) and GoogleTest's own targets are added via plain
# add_executable with no guard of their own, so without this they would join
# the parent project's default ALL target and get compiled on every ordinary
# flutter build/run/test -d windows. This only excludes native_build's own
# default-build targets; ${PLUGIN_NAME} still links pet_matte, frame_source
# and prepare_queue below, so CMake still builds those (and their
# dependencies matte_core, mf_decode, pcmat, lz4_static) on demand, as
# dependencies of a target that IS in ALL.
add_subdirectory("${AIPET_NATIVE_DIR}" native_build EXCLUDE_FROM_ALL)
target_link_libraries(${PLUGIN_NAME} PRIVATE pet_matte frame_source prepare_queue)

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(alpha_video_bundled_libraries
  ""
  PARENT_SCOPE
)

# No plugin-local native unit tests: the generated template's test block
# pinned GoogleTest to a version too old for this environment's CMake, and it
# would collide with the v1.15.2 already fetched by native/. The C ABI this
# plugin calls (pet_matte_abi_version) and the crop-expansion/BGRA->RGBA
# logic (FrameSource) are already covered by the native ctest suite
# (pet_matte_tests, frame_source_tests); coverage of the plugin's own glue
# code (method-channel wiring, texture registration) lives in the Flutter
# integration test instead.
