add_library(matte_core STATIC src/chroma_key.cpp src/despill.cpp src/crop.cpp)
target_include_directories(matte_core PUBLIC include)

add_executable(matte_core_tests tests/test_chroma_key.cpp tests/test_despill.cpp tests/test_crop.cpp)
target_link_libraries(matte_core_tests PRIVATE matte_core GTest::gtest_main)
gtest_discover_tests(matte_core_tests)
