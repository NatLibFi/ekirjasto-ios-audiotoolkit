//
//  ImageControlView.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 4/9/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import PureLayout

class ImageControlView: UIControl {
    var text: String? {
        get {
            return self.textLabel.text
        }
        set(newText) {
            self.textLabel.text = newText
        }
    }
    
    private let textLabel = UILabel()

    var image: UIImage? {
        get {
            return self.imageView.image
        }
        set(newImage) {
            self.imageView.image = newImage
        }
    }
    private var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.accessibilityIdentifier = "play_button"
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setup()
    }

    init() {
        super.init(frame: .zero)
        self.setup()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        self.accessibilityTraits = UIAccessibilityTraits.button
        self.isAccessibilityElement = true

        self.addSubview(self.imageView)
        self.imageView.autoPinEdgesToSuperviewEdges()
        
        self.addSubview(self.textLabel)
        self.textLabel.accessibilityIdentifier = "TextOverImageView.textLabel"
        self.textLabel.font = UIFont.systemFont(ofSize: 12)
        self.textLabel.textAlignment = .center
        self.textLabel.numberOfLines = 1
        self.textLabel.autoPinEdge(.top, to: .bottom, of: self.imageView, withOffset: 8)
        self.textLabel.autoAlignAxis(.vertical, toSameAxisOf: self.imageView)
        self.textLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
        self.textLabel.textColor = .label
    }
}
