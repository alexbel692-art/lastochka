Pod::Spec.new do |s|
  s.name             = 'video_frame'
  s.version          = '1.0.0'
  s.summary          = 'Video preview frame (Lastochka)'
  s.homepage         = 'https://github.com/alexbel692-art/lastochka'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Lastochka' => 'noreply@github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks       = 'AVFoundation'
  s.swift_version    = '5.0'
end
