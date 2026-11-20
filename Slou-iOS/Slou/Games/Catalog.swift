import SwiftUI

/// The display faces below contain a complete Cyrillic alphabet. Rules and controls use Dynamic Type.
enum ArcadeType {
    static func title(_ id: String, _ size: CGFloat) -> Font {
        switch id {
        case "race", "beat": return GFont.tektur.font(size)
        case "mines": return GFont.mono.font(size * 0.90)
        case "duel", "arm": return GFont.serif.font(size * 0.94)
        case "slice": return GFont.plex.font(size)
        case "range": return GFont.arsenal.font(size)
        case "hoop": return .system(size: size, weight: .heavy, design: .rounded)
        default: return GFont.inter.font(size)
        }
    }
}

struct GameInfo: Identifiable {
    let id: String
    let title: String
    let edition: String
    let color: Color
    let duration: Double
    let practiceDuration: Double
    let rules: [String]
    let make: (GameContext) -> StudioGame

    func rule(_ round: Int) -> String { rules[min(rules.count-1,max(0,round))] }
}

enum Arcade {
    static let games: [GameInfo] = [
        GameInfo(id:"box",title:"Бокс",edition:"Последний гонг",color:Color(hex:0xe8947c),duration:10,practiceDuration:27,
            rules:["Касание — джеб, свайп вверх — апперкот. Удерживай блок или уклонись свайпом в сторону.","После уклона соперник открыт для контратаки.","Следи за выносливостью и чередуй короткие и сильные удары."],make:BoxGame.init),
        GameInfo(id:"race",title:"Гонка",edition:"Серпантины",color:Color(hex:0xf4b571),duration:10,practiceDuration:43,
            rules:["Держи газ справа. Левым пальцем поворачивай руль. Перед виражом отпускай газ и жми тормоз.","Обгоняй на прямой. На обочине меньше сцепления.","На выходе из поворота выпрямляй руль и снова разгоняйся."],make:RaceGame.init),
        GameInfo(id:"mines",title:"Минёр",edition:"Глубинная разведка",color:Color(hex:0x77dac5),duration:13,practiceDuration:37,
            rules:["Веди аппарат по соседним клеткам. Собери два янтарных образца и доберись до стрелки наверху.","Сонар ненадолго показывает опасные клетки. Цифра означает число мин вокруг.","Долгим нажатием пометь опасную клетку. Три повреждения завершают погружение."],make:MinesGame.init),
        GameInfo(id:"duel",title:"Дуэль",edition:"Полдень",color:Color(hex:0xe6b97c),duration:6.2,practiceDuration:25,
            rules:["Зажми нижнюю плашку. После звонка веди палец к латунной печати и отпускай.","Ветер отвлекает. Дождись появления печати.","Чем ближе к центру и быстрее реакция, тем больше очков."],make:ShowdownGame.init),
        GameInfo(id:"slice",title:"Самурай",edition:"Сад на ветру",color:Color(hex:0xefb26f),duration:9,practiceDuration:25,
            rules:["Разрезай плоды взмахом пальца. Несколько плодов одним движением дают комбо.","Тёмные косточки прерывают серию.","Плоды с белой чертой разрезай вдоль метки."],make:SamuraiGame.init),
        GameInfo(id:"goal",title:"Пенальти",edition:"Девятка",color:Color(hex:0xf0c474),duration:11.5,practiceDuration:32,
            rules:["Проведи от мяча вверх. Направление и скорость задают удар, дуга пальца подкручивает мяч.","Золотая мишень в углу ворот даёт бонус.","Вратарь запоминает предыдущий удар. Меняй направление."],make:GoalGame.init),
        GameInfo(id:"range",title:"Тир",edition:"Бумажный порт",color:Color(hex:0xffcf86),duration:9.5,practiceDuration:25,
            rules:["Касайся заводных уток. После пяти выстрелов нажми рычаг или смахни вниз.","Пропускай синий флажок. За латунную звезду больше очков.","Держи серию точных попаданий. Промах сбрасывает её."],make:RangeGame.init),
        GameInfo(id:"arm",title:"Армрестлинг",edition:"Сила хвата",color:Color(hex:0xedc290),duration:7.5,practiceDuration:27,
            rules:["Удерживай хват, чтобы давить. Отпускай, чтобы вернуть выносливость.","Перед рывком соперника отпусти хват и зажми снова для перехвата.","Дожми руку соперника вправо, пока хватает сил."],make:ArmGame.init),
        GameInfo(id:"hoop",title:"Баскет",edition:"После школы",color:Color(hex:0xedaa7a),duration:10,practiceDuration:29,
            rules:["Свайпни мяч вверх. Длина свайпа задаёт высоту дуги. Прицелься по пунктиру.","Кольцо движется. Можно бросать от стекла.","Три точных броска подряд дают бонус."],make:HoopGame.init),
        GameInfo(id:"beat",title:"Ритм",edition:"Синкопа",color:Color(hex:0xd5ed97),duration:11,practiceDuration:30,
            rules:["Нажимай на одну из четырёх клавиш, когда нота касается линии. Длинную ноту удерживай до конца.","Аккорды бери двумя пальцами одновременно.","Темп растёт. В коротких связках играй между долями."],make:BeatGame.init)
    ]
}

struct PosterView: View {
    let game:GameInfo
    let label:String
    var body:some View {
        ZStack(alignment:.bottomLeading){
            ArcadeCover(id:game.id)
            LinearGradient(colors:[.clear,.black.opacity(0.18),.black.opacity(0.91)],startPoint:.top,endPoint:.bottom)
            VStack(alignment:.leading,spacing:9){
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(game.color)
                Text(game.edition).font(ArcadeType.title(game.id, 43)).tracking(-0.6).minimumScaleFactor(0.63)
                Text(game.rule(0)).font(.callout).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal:false,vertical:true)
            }.padding(24)
        }.foregroundStyle(.white).clipped()
    }
}
