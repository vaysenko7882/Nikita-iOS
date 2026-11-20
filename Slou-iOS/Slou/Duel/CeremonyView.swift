import SwiftUI

struct CeremonyView: View {
    let ceremony: Ceremony
    let done: ()->Void
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack{
            Color(hex: 0x101713).ignoresSafeArea()
            RadialGradient(colors: [Color(hex: ceremony.iWon ? 0x48513a: 0x2d3840), .clear], center: .topTrailing, startRadius: 0, endRadius: 550).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18){
                Spacer()
                Image(systemName: ceremony.iWon ? "crown.fill": "flag.checkered").font(.system(size: 48, weight: .light)).foregroundStyle(Color(hex: 0xe2d2a7))
                Text(ceremony.iWon ? "Победа": "Матч завершён").font(.system(size: 45, weight: .bold)).tracking(-1.8)
                Text(ceremony.practice ? "Демо-комната": "Битва за корону").font(.headline).foregroundStyle(.secondary)
                Divider().padding(.vertical, 7)
                row(ceremony.meName, ceremony.myScore)
                row(ceremony.opName, ceremony.theirScore)
                if !ceremony.practice {Text(ceremony.line).font(.subheadline).foregroundStyle(.secondary)}
                Spacer()
                Button(action: done){
                    Text(ceremony.practice ? "В демо-комнату": "В комнату").font(.headline).frame(maxWidth: .infinity, minHeight: 55)
                        .background(Color(hex: 0xe8eedf), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black)
                }.buttonStyle(.plain).accessibilityIdentifier("arena.result.return")
            }.padding(.horizontal, 24).padding(.bottom, 18).frame(maxWidth: 600)
        }.foregroundStyle(.white).opacity(visible ? 1: 0)
        .onAppear{withAnimation(reduceMotion ? nil: .easeOut(duration: 0.22)){visible = true}}
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }
    private func row(_ title: String, _ value: Int)->some View {
        HStack{Text(title).font(.title3.weight(.medium))
            Spacer()
            Text("\(value)").font(.system(size: 29, weight: .semibold)).monospacedDigit()}
    }
}
