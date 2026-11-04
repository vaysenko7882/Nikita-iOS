import AccountContext
import AsyncDisplayKit
import Display
import UIKit

final class CodeGramIconPickerController: ViewController {
    private let context: AccountContext
    private let picker: CodeGramIconPickerView
    private let scroll = UIScrollView()
    init(context: AccountContext) {
        self.context = context
        self.picker = CodeGramIconPickerView(currentName: context.sharedContext.applicationBindings.getAlternateIconName())
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = "Иконка приложения"
        self.picker.onSelection = { [weak self] choice in self?.statusBar.statusBarStyle = choice.light ? .Black : .White }
        self.picker.onPalette = { [weak self] color in
            guard let self, self.isNodeLoaded else { return }
            self.displayNode.backgroundColor = color
            self.scroll.backgroundColor = color
        }
        self.picker.onApply = { [weak self] choice in
            guard let self else { return }
            self.picker.setApplying(true)
            self.context.sharedContext.applicationBindings.requestSetAlternateIconName(choice.name, { [weak self] succeeded in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.picker.setApplying(false, appliedName: choice.name, succeeded: succeeded)
                    if !succeeded {
                        let alert = CodeGramPlainAlertController(title: "Иконка не изменена", message: "iOS не применила иконку. Попробуй ещё раз, когда приложение активно.", preferredStyle: .alert)
                        alert.addAction(CodeGramPlainAlertAction(title: "ОК", style: .default))
                        self.present(alert, animated: true)
                    }
                }
            })
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.view.addSubview(self.scroll)
        self.scroll.addSubview(self.picker)
        self.statusBar.statusBarStyle = CodeGramAppIconChoice.all[self.picker.selectedIndex].light ? .Black : .White
        self.displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.cleanNavigationHeight
        let height = max(0, layout.size.height - top - layout.intrinsicInsets.bottom)
        self.scroll.frame = CGRect(x: 0, y: top, width: layout.size.width, height: height)
        self.picker.frame = CGRect(x: 0, y: 0, width: layout.size.width, height: max(height, 1000))
        self.scroll.contentSize = self.picker.bounds.size
        self.displayNode.backgroundColor = self.picker.backgroundColor
    }
}

