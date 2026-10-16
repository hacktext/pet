# macOS 的 mfd::Decoder 实现（AVFoundation）。目标名沿用 mf_decode，
# 头文件也沿用 mf_decode/include，pet_matte 不用区分平台。
enable_language(OBJCXX)

add_library(mf_decode STATIC src/decoder.mm)
target_include_directories(mf_decode PUBLIC ../mf_decode/include)
target_compile_options(mf_decode PRIVATE -fobjc-arc)
target_link_libraries(mf_decode PUBLIC native_path
  "-framework AVFoundation" "-framework CoreMedia" "-framework CoreVideo" "-framework Foundation")

# 与 Windows 共用同一份解码器测试。
add_executable(mf_decode_tests ../mf_decode/tests/test_decoder.cpp)
target_compile_definitions(mf_decode_tests PRIVATE
  AIPET_TESTDATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../testdata")
target_link_libraries(mf_decode_tests PRIVATE mf_decode GTest::gtest_main)
gtest_discover_tests(mf_decode_tests)
