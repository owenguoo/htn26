# SwarmCore is the pure-Swift package two levels above `mobile/`. It is linked as
# a *local Swift package*, not vendored: `swift test` on macOS stays the source
# of truth for the logic, and this pod only adds what needs UIKit/ARKit.
swarm_core = File.expand_path('../../../../Packages/SwarmCore', __dir__)

Pod::Spec.new do |s|
  # Not 'SwarmSight': that is the app target's module name, and a pod that shares
  # it makes `import SwarmSight` inside the app resolve to the app itself — the
  # module class then silently disappears from Release builds.
  s.name           = 'SwarmSightNative'
  s.version        = '1.0.0'
  s.summary        = 'Native SwarmSight client: ARKit pose source, frame encoder, operator view.'
  s.description    = 'Hosts SwarmCore inside an Expo app. JS never touches frames, poses at rate, or the socket.'
  s.author         = ''
  s.homepage       = 'https://github.com/owenguoo/htn26'
  s.platforms      = { :ios => '17.0' }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version  = '6.0'

  s.dependency 'ExpoModulesCore'
  spm_dependency(s, url: swarm_core, requirement: { kind: 'upToNextMajorVersion', minimumVersion: '0.0.0' },
                 products: ['SwarmCore'])

  s.frameworks = 'ARKit', 'CoreHaptics', 'AVFoundation', 'CoreImage', 'Metal'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
  s.resource_bundles = {
    'SwarmSightResources' => ['Resources/**/*.{png,json}']
  }
end
