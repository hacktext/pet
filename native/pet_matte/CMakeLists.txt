add_library(pet_matte STATIC src/pet_matte.cpp)
target_include_directories(pet_matte PUBLIC include)
target_link_libraries(pet_matte PUBLIC pcmat matte_core mf_decode)

add_executable(pet_matte_tests tests/test_pipeline.cpp)
target_compile_definitions(pet_matte_tests PRIVATE
  AIPET_TESTDATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../testdata")
target_link_libraries(pet_matte_tests PRIVATE pet_matte GTest::gtest_main)
gtest_discover_tests(pet_matte_tests)
