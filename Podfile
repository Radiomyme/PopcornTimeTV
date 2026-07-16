use_frameworks!

source 'https://github.com/CocoaPods/Specs'
source 'https://github.com/PopcornTimeTV/Specs'

target 'PopcornTimetvOS' do
    platform :tvos, '17.0'
    pod 'PopcornTorrent', '~> 1.3.15'
    pod 'XCDYouTubeKit', '~> 2.9'
    pod 'Alamofire', '~> 5.9'
    pod 'AlamofireImage', '~> 4.3'
    # FloatRatingView 4.0 dropped tvOS support (podspec only declares iOS).
    # Pinned to 3.0.1 — last release that supports tvOS. The 4.0 changelog
    # just adds Swift 5 inferred property types, so we're not missing
    # anything functional.
    pod 'FloatRatingView', '3.0.1'
    pod 'ReachabilitySwift', '~> 5.2'
    pod 'MarqueeLabel', '~> 4.5'
    pod 'ObjectMapper', '~> 4.4'
    pod 'TvOSMoreButton', '~> 1.4'
    # Unified VLCKit 4.x (VLC 4.0 core) replaces the legacy per-platform
    # TVVLCKit/MobileVLCKit 3.7 (VLC 3.0). Brings VideoToolbox HEVC/AV1
    # decoding improvements, the rewritten track API, audio passthrough,
    # and — the reason for the upgrade — a shot at real HDR output on the
    # Apple TV 4K. Pinned to an explicit alpha (no stable 4.0 yet).
    pod 'VLCKit', '4.0.0a21'
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
    # Unified VLCKit 4.x (same pod as tvOS). Replaces MobileVLCKit 3.7.
    pod 'VLCKit', '4.0.0a21'
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
        name = target.name
        target.build_configurations.each do |config|
            # Force-bump deployment targets unconditionally so pods with old
            # xcconfig defaults (TVVLCKit's 10.2, GCDWebServer's 9.0, etc.)
            # don't trip Xcode 26's "below the minimum supported" warnings.
            # Platform-specific so an iOS-only pod doesn't accidentally get
            # a TVOS_DEPLOYMENT_TARGET key.
            # Bump every deployment-target field that's set, regardless of
            # which platform the pod targets. Xcode 26 demands ≥12 (iOS) /
            # ≥14 (tvOS) and warns otherwise. Setting both keys is harmless
            # — the linker uses whichever applies to the active SDK.
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
            config.build_settings['TVOS_DEPLOYMENT_TARGET']     = '17.0'

            config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]']  = 'arm64'
            config.build_settings['EXCLUDED_ARCHS[sdk=appletvsimulator*]'] = 'arm64'
            config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING']         = 'NO'

            # These are all vendored third-party pods we don't maintain, and a
            # clean build surfaces their "future Swift language mode" / label-
            # mismatch / Sendable warnings (ObjectMapper's TransformOperators,
            # AlamofireImage, …). Suppress Swift warnings pod-wide so the issue
            # navigator only shows warnings from OUR code.
            config.build_settings['SWIFT_SUPPRESS_WARNINGS'] = 'YES'

            # Restrict each pod target to its actual platform. CocoaPods names
            # them with `-iOS` / `-tvOS` suffixes; Xcode 26 otherwise tries to
            # compile both flavors for whatever scheme is active and fails on
            # platform-only frameworks (e.g. ReachabilitySwift-iOS needs
            # CoreTelephony which doesn't exist on tvOS).
            if name.end_with?('-iOS')
                config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
            elsif name.end_with?('-tvOS')
                config.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator'
            end

            # GCDWebServer ships a few decade-old Objective-C warnings (no
            # prototype, enum-mismatch ternary). They're in 3rd-party code
            # we can't patch upstream — silence them so they stop polluting
            # the issue navigator.
            # NOTE: with use_frameworks! + multi-platform, CocoaPods names the
            # target 'GCDWebServer-iOS' / 'GCDWebServer-tvOS' (not bare
            # 'GCDWebServer'), so match the prefix — an `== ` check silently
            # never fired, which is why these warnings kept showing up.
            if name.start_with?('GCDWebServer')
                config.build_settings['GCC_WARN_ABOUT_MISSING_PROTOTYPES']        = 'NO'
                config.build_settings['CLANG_WARN_STRICT_PROTOTYPES']             = 'NO'
                config.build_settings['CLANG_WARN_ENUM_CONVERSION']               = 'NO'
                config.build_settings['CLANG_WARN_IMPLICIT_FUNCTION_DECLARATION'] = 'NO'
                config.build_settings['CLANG_WARN_DOCUMENTATION_COMMENTS']        = 'NO'
                config.build_settings['GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS']      = 'NO'
                # A few warnings modern clang emits that the boolean settings
                # above don't cover: the iOS-15 UTType deprecations, the C
                # "declaration without a prototype" note, and the cross-enum
                # ternary in GCDWebServerConnection.m. Silence them via raw
                # -Wno flags since they're all in vendored 3rd-party code.
                inherited = config.build_settings['OTHER_CFLAGS'] || '$(inherited)'
                inherited = inherited.join(' ') if inherited.is_a?(Array)
                config.build_settings['OTHER_CFLAGS'] =
                    "#{inherited} -Wno-deprecated-declarations -Wno-deprecated-non-prototype -Wno-enum-compare-conditional"
            end
        end
    end

    # The aggregate Pods-PopcornTimetvOS / Pods-PopcornTimeiOS xcconfigs
    # inherit `-lc++ -liconv -lbz2 -lxml2 -lz` from VLCKit, AND VLCKit's own
    # xcconfig already lists those flags — Xcode 26 warns "Ignoring
    # duplicate libraries" on every build. De-duplicate the OTHER_LDFLAGS
    # in the aggregate xcconfigs (regenerated on every `pod install`).
    aggregate_dirs = Dir.glob('Pods/Target Support Files/Pods-*/')
    aggregate_dirs.each do |dir|
        Dir.glob(File.join(dir, '*.xcconfig')).each do |xc|
            content = File.read(xc)
            updated = content.lines.map do |line|
                next line unless line.start_with?('OTHER_LDFLAGS')
                key, _, rhs = line.partition('=')
                seen = []
                tokens = rhs.strip.split(/\s+/)
                deduped = tokens.reject do |t|
                    if t.start_with?('-l"') || t == '-framework'
                        if seen.include?(t)
                            true
                        else
                            seen << t; false
                        end
                    elsif tokens[tokens.index(t)&.- 1] == '-framework'
                        # framework name token following -framework — pair it
                        false
                    else
                        false
                    end
                end
                # Pair-aware framework dedup (because '-framework' and the
                # name token must both be present together to count as a flag).
                pairs = []
                out   = []
                i = 0
                while i < tokens.length
                    if tokens[i] == '-framework' && i + 1 < tokens.length
                        pair = "#{tokens[i]} #{tokens[i+1]}"
                        unless pairs.include?(pair)
                            pairs << pair
                            out << tokens[i] << tokens[i+1]
                        end
                        i += 2
                    else
                        unless out.include?(tokens[i])
                            out << tokens[i]
                        end
                        i += 1
                    end
                end
                "#{key.strip} = #{out.join(' ')}\n"
            end
            File.write(xc, updated.join)
        end
    end
end
