add_library(pcmat STATIC src/writer.cpp src/reader.cpp)
target_include_directories(pcmat PUBLIC include)
target_link_libraries(pcmat PUBLIC lz4_static native_path)

add_executable(pcmat_tests tests/test_format.cpp tests/test_roundtrip.cpp)
target_link_libraries(pcmat_tests PRIVATE pcmat GTest::gtest_main)
gtest_discover_tests(pcmat_tests)
