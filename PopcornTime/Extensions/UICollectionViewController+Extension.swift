

import Foundation

extension UICollectionViewController {

    @objc func collectionViewWillReloadData(_ collectionView: UICollectionView) { }
    @objc func collectionViewDidReloadData(_ collectionView: UICollectionView) { }

}

extension UICollectionView: Object {
    
    @objc private func pctReloadData() {
        if let parent = parent as? UICollectionViewController {
            parent.collectionViewWillReloadData(self)
            self.pctReloadData()
            parent.collectionViewDidReloadData(self)
        } else {
            self.pctReloadData()
        }
    }
    
    public static func awake() {
        DispatchQueue.once {
            guard let originalMethod = class_getInstanceMethod(self, #selector(reloadData)),
                  let swizzledMethod = class_getInstanceMethod(self, #selector(pctReloadData)) else { return }
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }
}
