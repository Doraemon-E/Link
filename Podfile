platform :ios, '15.0'
use_frameworks!

target 'link' do
  pod 'onnxruntime-objc'
  pod 'ZIPFoundation'
end

post_install do |installer|
  framework_name = 'onnxruntime_objc'
  onnx_headers = Dir.glob(
    File.join(installer.sandbox.root.to_s, 'onnxruntime-objc', 'objectivec', 'include', '*.h')
  )
  umbrella_header = File.join(
    installer.sandbox.root.to_s,
    'Target Support Files',
    'onnxruntime-objc',
    'onnxruntime-objc-umbrella.h'
  )

  (onnx_headers + [umbrella_header]).each do |path|
    next unless File.exist?(path)

    contents = File.read(path)
    updated = contents.gsub(/#import "([^"]+)"/, "#import <#{framework_name}/\\1>")
    File.write(path, updated) if updated != contents
  end

  installer.pods_project.targets.each do |target|
    next unless target.name == 'onnxruntime-objc'

    target.build_configurations.each do |config|
      config.build_settings['CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER'] = 'NO'
    end
  end

  installer.pods_project.save
end
