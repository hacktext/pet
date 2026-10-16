cmake_minimum_required(VERSION 3.20)
project(aipet_native CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options($<$<CXX_COMPILER_ID:MSVC>:/utf-8>)

include(FetchContent)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_Declare(googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG v1.15.2)
FetchContent_MakeAvailable(googletest)

FetchContent_Declare(lz4
  GIT_REPOSITORY https://github.com/lz4/lz4.git
  GIT_TAG v1.10.0
  SOURCE_SUBDIR build/cmake)
FetchContent_MakeAvailable(lz4)

enable_testing()
include(GoogleTest)

add_subdirectory(native_path)
add_subdirectory(pcmat)
add_subdirectory(matte_core)
# Decoder: Media Foundation on Windows, AVFoundation on macOS. Both build a
# target named mf_decode behind the same header. The Flutter macOS plugin
# compiles these sources through its podspec instead of this tree.
if(WIN32)
  add_subdirectory(mf_decode)
elseif(APPLE)
  add_subdirectory(avf_decode)
endif()
add_subdirectory(pet_matte)
add_subdirectory(frame_source)
add_subdirectory(prepare_queue)
