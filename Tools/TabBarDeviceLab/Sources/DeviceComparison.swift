import SwiftUI
import UIKit

struct DeviceComparison: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UITabBarController {
        let home = ComparisonHome()
        let profile = ComparisonList()
        home.onChange = { [weak profile] explicit in profile?.setBinding(explicit) }
        let bar = UITabBarController()
        bar.tabs = [
            UITab(title: "首页", image: UIImage(systemName: "house"), identifier: "home") { _ in home },
            UITab(title: "收藏", image: UIImage(systemName: "heart"), identifier: "favorites") { _ in UIViewController() },
            UITab(title: "历史", image: UIImage(systemName: "clock.arrow.circlepath"), identifier: "history") { _ in UIViewController() },
            UITab(title: "我的", image: UIImage(systemName: "person.crop.circle"), identifier: "profile") { _ in
                let nav = UINavigationController(rootViewController: profile)
                nav.navigationBar.prefersLargeTitles = true
                return nav
            },
            UISearchTab { _ in
                let search = UIViewController()
                search.view.backgroundColor = .systemBackground
                search.title = "搜索"
                search.navigationItem.searchController = UISearchController(searchResultsController: nil)
                return UINavigationController(rootViewController: search)
            }
        ]
        bar.tabBarMinimizeBehavior = .onScrollDown
        return bar
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {}
}

private final class ComparisonHome: UIViewController {
    var onChange: ((Bool) -> Void)?
    @objc private func selectionChanged(_ sender: UISegmentedControl) {
        let explicit = sender.selectedSegmentIndex == 1
        UserDefaults.standard.set(explicit, forKey: "lab-explicit-bottom")
        onChange?(explicit)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let title = UILabel()
        title.text = "底栏变色对照"
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title1)
        title.textAlignment = .center
        let chooser = UISegmentedControl(items: ["A · 自动", "B · 指定列表"])
        chooser.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "lab-explicit-bottom") ? 1 : 0
        chooser.addTarget(self, action: #selector(selectionChanged(_:)), for: .valueChanged)
        let hint = UILabel()
        hint.text = "选好后退到桌面，回到这个黑底首页，再点「我的」，先不要滑动。换另一组前建议从多任务界面退出测试版后重开。"
        hint.textColor = .white
        hint.font = .preferredFont(forTextStyle: .body)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, chooser, hint])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
}

private final class ComparisonList: UITableViewController {
    private var explicit = UserDefaults.standard.bool(forKey: "lab-explicit-bottom")

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("No storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "我的"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        applyBinding()
    }

    func setBinding(_ enabled: Bool) {
        explicit = enabled
        if isViewLoaded { applyBinding() }
    }

    private func applyBinding() {
        setContentScrollView(explicit ? tableView : nil, for: .bottom)
        if explicit {
            let verified = contentScrollView(for: .bottom) === tableView
            print("TAB-BAR LAB: explicit bottom binding identity \(verified)")
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 60 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "对照列表 \(indexPath.row + 1)"
        cell.contentConfiguration = content
        return cell
    }
}
