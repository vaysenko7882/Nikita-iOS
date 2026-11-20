import pathlib
js = pathlib.Path('' + str(pathlib.Path(__file__).resolve().parent.parent / 'bridge' / 'SlouBridge.js') + '').read_text()
assert '"""#' not in js and '\\#(' not in js
out = '''// Сгенерировано из bridge/SlouBridge.js (embed_bridge.py) — правь исходник, не этот файл.
import Foundation

/// Скрипт, который приложение встраивает в страницу раньше её собственного кода
enum BridgeScript {
    static let source = #"""
''' + js + '''"""#
}
'''
pathlib.Path('' + str(pathlib.Path(__file__).resolve().parent.parent / 'Slou' / 'BridgeScript.swift') + '').write_text(out)
print('ok', len(js))
