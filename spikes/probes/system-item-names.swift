import Foundation
let h = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
// static init(stringValue:) -> MBSystemItemIdentifier?   (no self; String in x0/x1, result byte in x0; 9 == nil)
let fn = dlsym(h, "$s17MenuBarClientCore22MBSystemItemIdentifierO11stringValueACSgSS_tcfC")!
func lookup(_ s: String) -> UInt8 {
  // The callee consumes the String (+1); hand it a leaked copy so we never over-release.
  let p = UnsafeMutablePointer<String>.allocate(capacity: 1)
  p.initialize(to: s)
  let words = UnsafeRawPointer(p)
  let r = call_from_string(fn, words.load(as: UInt64.self), words.load(fromByteOffset: 8, as: UInt64.self))
  return r.isNil ? 255 : UInt8(r.value)
}
if CommandLine.arguments.count > 1 { print(lookup(CommandLine.arguments[1])); exit(0) }
let bases = ["controlcentre","control-center","control_center","cc","controlCenter","focusModes","nowPlaying","screenMirroring","keyboard","input","inputmenu","inputsource","airplay","stage","accessibilityshortcuts","fastuser","userswitcher","usermenu","account","clock","battery","wifi","bluetooth","displays","volume","airdrop","hotspot","siri","spotlight","timemachine","vpn","weather","focus","dnd","donotdisturb","doNotDisturb","notification","notifications","menubar","overflow","chevron","hidden","more","extras","audio","music","media","nowplaying","mirroring","screen","sharing","screensharing","recording","privacy","indicator","location","camera","mic","microphone","game","gamecontroller","keyboardbrightness","brightness","textinput","user","ink","script","hearing","weather","stocks","shortcuts","translate","ai","appleintelligence","intelligence","assistant","siri-ai","battery","bluetooth","clock","wifi","controlcenter","focusmode","focus","sound","volume","display","displays","airplay","screenmirroring","nowplaying","siri","spotlight","user","fastuserswitching","textinput","keyboardbrightness","timemachine","vpn","accessibility","hearing","stagemanager","weather","airdrop","audiovideo","av","camera","microphone","privacy","recording","screenrecording","menuextra","cellular","personalhotspot","hotspot","ink","script","eject","tty","ppp","iChat","presentation","gamemode","musicrecognition","shazam","notificationcenter","widgets","dock","clockextra","date","time","bentobox","wi-fi","airport","ScreenMirroring","AirPort","Battery","Bluetooth","Clock","Volume","Display","Siri","Spotlight","User","TextInput","FocusModes","NowPlaying","Sound","ControlCenter","WiFi"]
var hits: [UInt8: [String]] = [:]
for b in bases {
  for s in [b, b.lowercased(), "com.apple.menuextra.\(b.lowercased())"] {
    let r = lookup(s)
    if r < 9 { hits[r, default: []].append(s) }
  }
}
for k in hits.keys.sorted() { print(k, Array(Set(hits[k]!)).sorted()) }
