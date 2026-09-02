add_library(frame_source STATIC src/frame_source.cpp)
target_include_directories(frame_source PUBLIC include)
target_link_libraries(frame_source PUBLIC pcmat)

add_executable(frame_source_tests tests/test_frame_source.cpp)
target_link_libraries(frame_source_tests PRIVATE frame_source GTest::gtest_main)
gtest_discover_tests(frame_source_tests)
