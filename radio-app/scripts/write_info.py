import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={
 'CFBundleDevelopmentRegion':'ru','CFBundleExecutable':'NaSvyazi','CFBundleIdentifier':'app.nasvyazi.walkie',
 'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'На связи','CFBundleDisplayName':'На связи',
 'CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1',
 'MinimumOSVersion':'16.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1],
 'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],
 'NSMicrophoneUsageDescription':'Микрофон передаёт твой голос другу только пока ты удерживаешь аватар или кнопку рации.',
 'NSLocalNetworkUsageDescription':'Чтобы находить друзей с вашим общим кодом и передавать голос между iPhone рядом.',
 'NSBonjourServices':['_svyazi-ptt._tcp','_svyazi-ptt._udp'],
 'UIBackgroundModes':['audio','push-to-talk'],'UIApplicationSupportsIndirectInputEvents':True,
 'CFBundleURLTypes':[{'CFBundleURLName':'app.nasvyazi.walkie','CFBundleURLSchemes':['nasvyazi']}]
}
if len(sys.argv)>2 and Path(sys.argv[2]).exists():info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
(app/'Info.plist').write_bytes(plistlib.dumps(info))
