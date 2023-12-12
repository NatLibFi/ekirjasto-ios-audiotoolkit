//
//  UIButton+EkirjastoImageWithLabel.swift
//  Ekirjasto
//
//  Created by Nianzu on 11.9.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import UIKit

extension UIButton {
    func imageTopLabelDown(padding: CGFloat = 6, paddingTop: CGFloat = 5) {
      guard let image = imageView?.image, let label = titleLabel,
            let string = label.text else { return }
      
      titleEdgeInsets = UIEdgeInsets(top: padding, left: -image.size.width, bottom: -(image.size.height + paddingTop), right: 0)
      let titleSize = string.size(withAttributes: [NSAttributedString.Key.font: label.font])
      imageEdgeInsets = UIEdgeInsets(top: -(titleSize.height + padding) + paddingTop, left: 0, bottom: 0, right: -titleSize.width)
  }
}
