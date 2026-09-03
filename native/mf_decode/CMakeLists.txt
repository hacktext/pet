add_library(mf_decode STATIC src/decoder.cpp)
target_include_directories(mf_decode PUBLIC include)
target_link_libraries(mf_decode PUBLIC mfplat mfreadwrite mfuuid ole32 propsys)

add_executable(mf_decode_tests tests/test_decoder.cpp)
target_compile_definitions(mf_decode_tests PRIVATE
  AIPET_TESTDATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../testdata")
target_link_libraries(mf_decode_tests PRIVATE mf_decode GTest::gtest_main)
gtest_discover_tests(mf_decode_tests)
