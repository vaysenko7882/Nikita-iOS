import SwiftUI

/// Картинка дня для «Поделиться»: дата, циферблат и итог. Без имени и ника.
struct DayShareCard: View {
    let title: String
    let online: String
    let caption: String
    let segments: [DialSegment]
    let dayStart: Double
    let dayEnd: Double

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.rounded(22))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ZStack {
                Canvas { context, size in
                    DialPainter.paint(&context, size: size, segments: segments, dayStart: dayStart, dayEnd: dayEnd)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.on).frame(width: 8, height: 8)
                        Text("в сети")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    Text(online)
                        .font(.rounded(36))
                        .tracking(-1)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                }
                .frame(width: 170)
            }
            .frame(width: 300, height: 300)
            .padding(.top, 14)
        }
        .padding(30)
        .frame(width: 360)
        .background(Palette.page)
    }
}
