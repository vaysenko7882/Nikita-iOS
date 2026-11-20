import SwiftUI
import AVFoundation

final class BeatGame: StudioGame {
    override var fieldID: String {"beat"}
    override var accent: Color{Color(hex: 0xd5f68a)}
    private enum Judgement {case pending, held, done, missed}
    private struct Note {let lane: Int, at: Double, length: Double
        var state = Judgement.pending
        var value = 0}
    private var chart: [Note] = [], hands: [Int: Int] = [:], sustains: [Int: Int] = [:]
    private var soundtrack: AVAudioPlayer?, maximum = 0, total = 0, chain = 0
    private var flashes = [Double](repeating: -5, count: 4)
    private let colors = [Color(hex: 0xd4f97f), Color(hex: 0x88dccc), Color(hex: 0xc0a7ff), Color(hex: 0xf4a59b)]
    private var rate: Double{[0.95, 1.0, 1.1][R]}
    private var period: Double{60/(110*rate)}
    private var strike: CGFloat{height*0.79}
    private var clock: Double { if !c.effectsEnabled { return elapsed }
        if let t = soundtrack, t.isPlaying {return t.currentTime/rate}
        return max(0, gameNow()-t0/1000) }
    override func begin(){
        let phrase = [0, 2, 1, 3, 0, 1, 3, 2, 1, 3, 2, 0, 3, 1, 2, 0]
        var beat = 3.0, i = 0
        while beat*period < duration-1.1 {
            let sustain = i%8==4, span = sustain ? 1.25*period: 0, lane = phrase[(i+R*3)%phrase.count]
            chart.append(Note(lane: lane, at: beat*period, length: span))
            maximum+=sustain ? 3: 2
            if R>0 && i%8==6 {chart.append(Note(lane: (lane+2)%4, at: beat*period, length: 0))
                maximum+=2}
            beat += sustain ? 2 : (R==2 && i%6==2 ? 0.5: 1)
            i+=1
        }
        guard c.effectsEnabled else { return }
        if let url = Bundle.main.url(forResource: "pulse110", withExtension: "m4a") ?? Bundle.main.url(forResource: "pulse110", withExtension: "m4a", subdirectory: "Sounds") {
            soundtrack = try? AVAudioPlayer(contentsOf: url)
            soundtrack?.enableRate = true
            soundtrack?.rate = Float(rate)
            soundtrack?.volume = 0.70*Sound.shared.master
            soundtrack?.prepareToPlay()
            soundtrack?.play()
        }
    }
    override func end(){soundtrack?.stop()
        soundtrack = nil
        hands.removeAll()
        sustains.removeAll()}
    override func score()->Int {maximum==0 ? 0: clamp(Int((Double(total)*100/Double(maximum)).rounded()), 0, 100)}
    private func laneX(_ lane: Int, y: CGFloat)->CGFloat {
        let t = clamp((y-height*0.16)/(strike-height*0.16), 0, 1.25)
        return width/2+(CGFloat(lane)-1.5)*width*lerp(0.110, 0.225, t)
    }
    private func release(_ id: Int, cancelled: Bool) {
        if let n = sustains.removeValue(forKey: id), chart[n].state == .held {
            if !cancelled && clock>=chart[n].at+chart[n].length-0.12 {total+=1
                chart[n].state = .done
                chain+=1
                toast("Удержано", color: accent, seconds: 0.42)}
            else {chart[n].state = .missed
                chain = 0}
        }
        hands[id] = nil
    }
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double){
        switch phase{
        case .began:
            guard p.y>=height*0.48 else{return}
            let lane = clamp(Int(p.x/(width/4)), 0, 3)
            hands[id] = lane
            flashes[lane] = elapsed
            let t = clock
            guard let n = chart.indices.filter({chart[$0].lane==lane && chart[$0].state == .pending && abs(chart[$0].at-t)<0.18}).min(by: {abs(chart[$0].at-t)<abs(chart[$1].at-t)}) else{chain = 0
                return}
            let exact = abs(chart[n].at-t)<0.09
            total+=exact ? 2: 1
            chain+=1
            if chart[n].length>0 {chart[n].state = .held
                sustains[id] = n}else{chart[n].state = .done}
            sfx("note\([0, 3, 7, 10][lane])", 0.55)
            buzz("light")
            toast(exact ? "В долю": "Есть", color: colors[lane], seconds: 0.38)
        case .ended: release(id, cancelled: false)
        case .cancelled: release(id, cancelled: true)
        case .moved: break
        }
    }
    override func simulate(_ dt: Double){
        let t = clock
        for i in chart.indices {
            if chart[i].state == .pending && t>chart[i].at+0.19 {chart[i].state = .missed
                chain = 0}
            if chart[i].state == .held && t>=chart[i].at+chart[i].length {
                chart[i].state = .done
                total+=1
                sfx("hat", 0.35)
            }
        }
    }
    override func render(_ g: inout GraphicsContext){
        let t = live ? clock: 0, travel = period*3.6, start = height*0.16
        for i in 0..<4{
            let top = laneX(i, y: start), bottom = laneX(i, y: strike), hw = width*0.108
            let path = Shape2.poly([P(top-width*0.050, start), P(top+width*0.050, start), P(bottom+hw, strike+15), P(bottom-hw, strike+15)])
            g.fillColor(path, Color.black.opacity(0.54))
            strokeLine(&g, [P(top-width*0.050, start), P(bottom-hw, strike+15)], colors[i].opacity(0.33))
            if t>0 && (hands.values.contains(i) || elapsed-flashes[i]<0.17){g.fillColor(path, colors[i].opacity(0.22))}
            g.fillColor(Shape2.rrect(bottom-hw, strike-3, hw*2, 6, 3), colors[i])
            let pad = CGRect(x: CGFloat(i)*width/4+5, y: strike+27, width: width/4-10, height: max(42, min(72, height-strike-42)))
            g.fillColor(Path(roundedRect: pad, cornerRadius: 12), colors[i].opacity(hands.values.contains(i) ? 0.66: 0.19))
            mark(&g, ["circle", "diamond", "triangle", "square"][i], CGRect(x: pad.midX-9, y: pad.midY-9, width: 18, height: 18), colors[i])
        }
        for note in chart where note.state == .pending || note.state == .held {
            let k = 1-(note.at-t)/travel
            guard k>0 && k<1.92 else{continue}
            let y = note.state == .held ? strike: min(strike+21, start+CGFloat(k*k)*(strike-start))
            let x = laneX(note.lane, y: y), hw = lerp(9, width*0.09, CGFloat(clamp(k, 0, 1)))
            if note.length>0 {
                let tail = clamp(1-(note.at+note.length-t)/travel, 0, 1), yt = start+CGFloat(tail*tail)*(strike-start)
                strokeLine(&g, [P(laneX(note.lane, y: yt), yt), P(x, y)], colors[note.lane].opacity(0.73), 8)
            }
            g.fillColor(Shape2.rrect(x-hw, y-4, hw*2, 9, 4), colors[note.lane])
        }
        hud(&g, left: "Синкопа", value: "Комбо ×\(chain)", right: "\(Int((110*rate).rounded())) BPM")
    }

    override func playTurn(_ pilot: ArcadePilot) {
        for id in Array(pilot.hands.keys) {
            if let n = sustains[id], clock < chart[n].at + chart[n].length { continue }
            pilot.up(id)
        }
        for i in chart.indices where chart[i].state == .pending && !pilot.attemptedNotes.contains(i) {
            let late = clock-chart[i].at
            guard late >= 0 && late < 0.15 else { continue }
            pilot.attemptedNotes.insert(i)
            if pilot.random.chance(0.44+0.53*pilot.skill) {
                let note = chart[i]
                pilot.down(note.lane+1, at: P(width*(CGFloat(note.lane)+0.5)/4, strike+45))
            }
        }
        pilot.wait(0.035)
    }
}
