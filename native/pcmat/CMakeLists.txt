add_library(pcmat INTERFACE)
target_include_directories(pcmat INTERFACE include)

add_executable(pcmat_tests tests/test_format.cpp)
target_link_libraries(pcmat_tests PRIVATE pcmat GTest::gtest_main)
gtest_discover_tests(pcmat_tests)
