use_frameworks!

source 'https://github.com/CocoaPods/Specs'
source 'https://github.com/PopcornTimeTV/Specs'

def pods
    pod 'PopcornTorrent', '~> 1.3.15'
    pod 'XCDYouTubeKit', '~> 2.9'
    pod 'Alamofire', '~> 5.9'
    pod 'AlamofireImage', '~> 4.3'
    pod 'FloatRatingView', '3.0.1'
    pod 'ReachabilitySwift', '~> 5.2'
    pod 'MarqueeLabel', '~> 4.5'
    pod 'ObjectMapper', '~> 4.4'
end

target 'PopcornTimetvOS' do
    platform :tvos, '17.0'
    pods
    pod 'TvOSMoreButton', '~> 1.4'
    pod 'TVVLCKit', '~> 3.7'
    pod 'MBCircularProgressBar', '0.3.5-1'
end

target 'TopShelf' do
    platform :tvos, '17.0'
    pod 'ObjectMapper', '~> 4.4'
end

def kitPods
    pod 'Alamofire', '~> 5.9'
    pod 'ObjectMapper', '~> 4.4'
end

target 'PopcornKit tvOS' do
    platform :tvos, '17.0'
    kitPods
end
