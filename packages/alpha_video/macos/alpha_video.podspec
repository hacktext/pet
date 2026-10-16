#
# alpha_video for macOS (Apple silicon only).
#
# The rendering core lives in the repo's native/ tree, outside this pod.
# CocoaPods only compiles files under the pod root, so Classes/native/ holds
# one-line forwarding sources that #include the real ones through the header
# search paths below. The paths are resolved from this file's real location:
# Flutter reaches the plugin through a symlink in macos/Flutter/ephemeral.
#
native_dir = File.expand_path('../../../native', File.realpath(__dir__))

Pod::Spec.new do |s|
  s.name             = 'alpha_video'
  s.version          = '0.0.1'
  s.summary          = 'Transparent pet video playback (matted .aipmat clips) for aipet.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'Proprietary', :text => 'Private' }
  s.author           = { 'aipet' => 'user@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm,c,cpp}'
  s.public_header_files = 'Classes/AlphaVideoPlugin.h'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'Accelerate', 'AVFoundation', 'CoreMedia', 'CoreVideo'

  s.platform = :osx, '11.0'
  s.requires_arc = true
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ARCHS' => 'arm64',
    'EXCLUDED_ARCHS' => 'x86_64',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Objective-C++ does not autolink modules, so FlutterMacOS is named here.
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS',
    'HEADER_SEARCH_PATHS' => [
      native_dir,
      "#{native_dir}/native_path/include",
      "#{native_dir}/matte_core/include",
      "#{native_dir}/pcmat/include",
      "#{native_dir}/mf_decode/include",
      "#{native_dir}/frame_source/include",
      "#{native_dir}/pet_matte/include",
      "#{native_dir}/prepare_queue/include",
      '"${PODS_TARGET_SRCROOT}/Classes/third_party/lz4"',
    ].map { |p| p.start_with?('"') ? p : "\"#{p}\"" }.join(' '),
  }
  s.swift_version = '5.0'
end
