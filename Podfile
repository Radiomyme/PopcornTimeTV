use_frameworks!

source 'https://github.com/CocoaPods/Specs'
source 'https://github.com/PopcornTimeTV/Specs'

def pods
    pod 'PopcornTorrent', '~> 1.1.13'
    pod 'XCDYouTubeKit', '~> 2.5.6'
    pod 'Alamofire', '~> 5.10'
    pod 'AlamofireImage', '~> 4.3'
    pod 'FloatRatingView', '~> 4.2'
    pod 'ReachabilitySwift', '~> 5.2'
    pod 'MarqueeLabel', '~> 4.5'
    pod 'ObjectMapper', '~> 4.4'
end

target 'PopcornTimetvOS' do
    platform :tvos, '17.0'
    pods
    pod 'TvOSMoreButton', '~> 1.0'
    pod 'TVVLCKit', '~> 3.5'
    pod 'MBCircularProgressBar', '~> 0.4'
end

target 'TopShelf' do
    platform :tvos, '17.0'
    pod 'ObjectMapper', '~> 4.4'
end

def kitPods
    pod 'Alamofire', '~> 5.10'
    pod 'ObjectMapper', '~> 4.4'
    pod 'AlamofireXMLRPC', '~> 2.4'
end

target 'PopcornKit tvOS' do
    platform :tvos, '17.0'
    kitPods
end
