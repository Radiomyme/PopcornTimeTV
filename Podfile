use_frameworks!

source 'https://github.com/CocoaPods/Specs'
source 'https://github.com/PopcornTimeTV/Specs'

target 'PopcornTimetvOS' do
    platform :tvos, '17.0'
    pod 'PopcornTorrent', '~> 1.3.15'
    pod 'XCDYouTubeKit', '~> 2.9'
    pod 'Alamofire', '~> 5.9'
    pod 'AlamofireImage', '~> 4.3'
    pod 'FloatRatingView', '3.0.1'
    pod 'ReachabilitySwift', '~> 5.2'
    pod 'MarqueeLabel', '~> 4.5'
    pod 'ObjectMapper', '~> 4.4'
    pod 'TvOSMoreButton', '~> 1.4'
    pod 'TVVLCKit', '~> 3.7'
    pod 'MBCircularProgressBar', '0.3.5-1'
end

# iOS app uses SwiftUI + AVPlayer (no VLC — drops MobileVLCKit. .mkv won't
# play here; SwiftUI build is for AVPlayer-friendly content. PopcornTorrent
# is shared from CocoaPods PopcornTimeTV/Specs.) XCDYouTubeKit dropped
# because its iOS-8 deployment target hits Xcode 14.3+ libarclite removal.
target 'PopcornTimeiOS' do
    platform :ios, '17.0'
    pod 'PopcornTorrent', '~> 1.3.15'
    pod 'Alamofire', '~> 5.9'
    pod 'AlamofireImage', '~> 4.3'
    pod 'ReachabilitySwift', '~> 5.2'
    pod 'ObjectMapper', '~> 4.4'
end

target 'TopShelf' do
    platform :tvos, '17.0'
    pod 'ObjectMapper', '~> 4.4'
end

# PopcornKit framework is shared between iOS and tvOS apps.
def kitPods
    pod 'Alamofire', '~> 5.9'
    pod 'ObjectMapper', '~> 4.4'
end

target 'PopcornKit tvOS' do
    platform :tvos, '17.0'
    kitPods
end

target 'PopcornKit iOS' do
    platform :ios, '17.0'
    kitPods
end

# Bump pod deployment targets that are too old for Xcode 26 (12.0 minimum
# for iOS, 14.0 minimum for tvOS) and force EXCLUDED_ARCHS for arm64
# simulator on Apple Silicon Macs (PopcornTorrent's xcframework only
# ships an x86_64 simulator slice).
post_install do |installer|
    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            ios = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
            if ios && Gem::Version.new(ios.to_s) < Gem::Version.new('12.0')
                config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
            end
            tv = config.build_settings['TVOS_DEPLOYMENT_TARGET']
            if tv && Gem::Version.new(tv.to_s) < Gem::Version.new('14.0')
                config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '14.0'
            end
            config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
            config.build_settings['EXCLUDED_ARCHS[sdk=appletvsimulator*]'] = 'arm64'
            config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'

            # Restrict each pod target to its actual platform. CocoaPods names
            # them with `-iOS` / `-tvOS` suffixes; Xcode 26 otherwise tries to
            # compile both flavors for whatever scheme is active and fails on
            # platform-only frameworks (e.g. ReachabilitySwift-iOS needs
            # CoreTelephony which doesn't exist on tvOS).
            name = target.name
            if name.end_with?('-iOS')
                config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
            elsif name.end_with?('-tvOS')
                config.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator'
            end
        end
    end
end
