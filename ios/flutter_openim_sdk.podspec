Pod::Spec.new do |s|
  s.name             = 'flutter_openim_sdk'
  s.version          = '0.0.1'
  s.summary          = 'Flutter wrapper for the OpenIM native C++ SDK.'
  s.description      = <<-DESC
An FFI bridge bundling the openim-sdk-cpp-3.8.3-patch.10 iOS framework build.
  DESC
  s.homepage         = 'https://opensource.nween.com/flutter_openim_sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'OpenIM Contributors' => 'opensource@nween.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*', 'Headers/**/*'
  s.vendored_frameworks = 'openim_sdk_ffi.xcframework'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64'
  }
end
