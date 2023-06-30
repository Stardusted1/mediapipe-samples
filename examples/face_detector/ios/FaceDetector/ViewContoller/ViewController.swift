// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import MediaPipeTasksVision
import UniformTypeIdentifiers
import AVKit

class ViewController: UIViewController {

  // MARK: Storyboards Connections
  @IBOutlet weak var previewView: PreviewView!
  @IBOutlet weak var overlayView: OverlayView!
  @IBOutlet weak var addImageButton: UIButton!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var imageEmptyLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var runningModelTabbar: UITabBar!
  @IBOutlet weak var cameraTabbarItem: UITabBarItem!
  @IBOutlet weak var photoTabbarItem: UITabBarItem!
  @IBOutlet weak var bottomSheetViewBottomSpace: NSLayoutConstraint!
  @IBOutlet weak var bottomViewHeightConstraint: NSLayoutConstraint!

  // MARK: Constants
  private let delayBetweenInferencesMs = 50.0
  private let inferenceBottomHeight = 170.0
  private let expandButtonHeight = 41.0
  private let edgeOffset: CGFloat = 2.0
  private let labelOffset: CGFloat = 10.0
  private let displayFont = UIFont.systemFont(ofSize: 14.0, weight: .medium)
  private let ovelayColor = UIColor(red: 0, green: 127/255.0, blue: 139/255.0, alpha: 1)
  private let playerViewController = AVPlayerViewController()
  private var generator:AVAssetImageGenerator?

  // MARK: Instance Variables
  private var videoDetectTimer: Timer?
  private var previousInferenceTimeMs = Date.distantPast.timeIntervalSince1970 * 1000
  private var minSuppressionThreshold = DefaultConstants.minSuppressionThreshold
  private var minDetectionConfidence = DefaultConstants.minDetectionConfidence
  private var modelPath = DefaultConstants.modelPath
  private var runingModel: RunningMode = .video {
    didSet {
      faceDetectorHelper = FaceDetectorHelper(
        modelPath: modelPath,
        minDetectionConfidence: minDetectionConfidence,
        minSuppressionThreshold: minSuppressionThreshold,
        runningModel: runingModel
      )
    }
  }
  private var isProcess = false

  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraCapture = CameraFeedManager(previewView: previewView)

  // Handles all data preprocessing and makes calls to run inference through the
  // `FaceDetectorHelper`.
  private var faceDetectorHelper: FaceDetectorHelper?

  // Handles the presenting of results on the screen
  private var inferenceViewController: InferenceViewController?

  // MARK: View Handling Methods
  override func viewDidLoad() {
    super.viewDidLoad()
    // Create face detector helper
    faceDetectorHelper = FaceDetectorHelper(
      modelPath: modelPath,
      minDetectionConfidence: minDetectionConfidence,
      minSuppressionThreshold: minSuppressionThreshold,
      runningModel: runingModel
    )

    runningModelTabbar.selectedItem = cameraTabbarItem
    runningModelTabbar.delegate = self
    cameraCapture.delegate = self
    overlayView.clearsContextBeforeDrawing = true
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
#if !targetEnvironment(simulator)
    if runingModel == .video {
      cameraCapture.checkCameraConfigurationAndStartSession()
    }
#endif
  }

#if !targetEnvironment(simulator)
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraCapture.stopSession()
  }
#endif

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return .lightContent
  }

  // MARK: Storyboard Segue Handlers
  override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
    super.prepare(for: segue, sender: sender)
    if segue.identifier == "EMBED" {
      inferenceViewController = segue.destination as? InferenceViewController
      inferenceViewController?.minDetectionConfidence = minDetectionConfidence
      inferenceViewController?.minSuppressionThreshold = minSuppressionThreshold
      inferenceViewController?.delegate = self
      bottomViewHeightConstraint.constant = inferenceBottomHeight
      bottomSheetViewBottomSpace.constant = -inferenceBottomHeight + expandButtonHeight
      view.layoutSubviews()
    }
  }

  // MARK: IBAction

  @IBAction func addPhotoButtonTouchUpInside(_ sender: Any) {
    openImagePickerController()
  }
  // Resume camera session when click button resume
  @IBAction func resumeButtonTouchUpInside(_ sender: Any) {
    cameraCapture.resumeInterruptedSession { isSessionRunning in
      if isSessionRunning {
        self.resumeButton.isHidden = true
        self.cameraUnavailableLabel.isHidden = true
      }
    }
  }

  // MARK: - Test
  func drawOnImage(_ image: UIImage, boxs: [CGRect]) -> UIImage {

    UIGraphicsBeginImageContext(image.size)
    image.draw(at: CGPoint.zero)
    let context = UIGraphicsGetCurrentContext()!
    context.setStrokeColor(UIColor.red.cgColor)
    context.setLineWidth(20)
    context.addRects(boxs)
    context.drawPath(using: .stroke)
    let myImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return myImage!
  }

  // MARK: Private function
  private func openImagePickerController() {
    if UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) {
      let imagePicker = UIImagePickerController()
      imagePicker.delegate = self
      imagePicker.sourceType = .savedPhotosAlbum
      imagePicker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
      imagePicker.allowsEditing = false
      imagePicker.modalPresentationStyle = .currentContext
      present(imagePicker, animated: true, completion: nil)
    }
  }

  private func removePlayerViewController() {
    playerViewController.view.removeFromSuperview()
    playerViewController.removeFromParent()
  }

  private func processVideo(url: URL) {
    let player = AVPlayer(url: url)
    let asset:AVAsset = AVAsset(url: url)
    generator = AVAssetImageGenerator(asset:asset)
    generator?.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
    generator?.requestedTimeToleranceAfter = CMTimeMake(value: 1, timescale: 25)
    generator?.appliesPreferredTrackTransform = true
    playerViewController.player = player
    playerViewController.showsPlaybackControls = false
    playerViewController.view.frame = previewView.bounds
    playerViewController.videoGravity = .resizeAspectFill
    previewView.addSubview(playerViewController.view)
    addChild(playerViewController)
    player.play()
    NotificationCenter.default.removeObserver(self)
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(playerDidFinishPlaying),
                   name: .AVPlayerItemDidPlayToEndTime,
                   object: player.currentItem
      )

    videoDetectTimer?.invalidate()
    videoDetectTimer = Timer.scheduledTimer(
      timeInterval: delayBetweenInferencesMs/1000,
      target: self,
      selector: #selector(detectionVideoFrame),
      userInfo: nil,
      repeats: true)
  }

  @objc func detectionVideoFrame() {
    guard let player = playerViewController.player else { return }
    let currentTime: CMTime = player.currentTime()
    guard let image = self.imageFromCurrentPlayer(fromTime: currentTime) else { return }
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    let result = self.faceDetectorHelper?.detect(videoFrame: image, timeStamps: Int(currentTimeMs))

    // Display results by handing off to the InferenceViewController.
    inferenceViewController?.faceDetectorHelperResult = result
    DispatchQueue.main.async {
      self.inferenceViewController?.updateData()
      self.drawAfterPerformingCalculations(onDetections: result?.faceDetectorResult?.detections ?? [], withImageSize: image.size)
    }
  }

  @objc func playerDidFinishPlaying(note: NSNotification) {
    videoDetectTimer?.invalidate()
    videoDetectTimer = nil
  }

  private func imageFromCurrentPlayer(fromTime: CMTime) -> UIImage? {
    let image:CGImage?
    do {
      try image = generator?.copyCGImage(at:fromTime, actualTime:nil)
    } catch {
      print(error)
       return nil
    }
    guard let image = image else { return nil }
    return UIImage(cgImage:image)
  }

  // MARK: Handle ovelay function
  /**
   This method takes the results, translates the bounding box rects to the current view, draws the bounding boxes, classNames and confidence scores of inferences.
   */
  private func drawAfterPerformingCalculations(onDetections detections: [Detection], withImageSize imageSize:CGSize) {

    overlayView.objectOverlays = []
    overlayView.setNeedsDisplay()

    guard !detections.isEmpty else {
      return
    }

    var objectOverlays: [ObjectOverlay] = []
    var index = 0
    for detection in detections {
      index += 1

      guard let category = detection.categories.first else { continue }
      // Translates bounding box rect to current view.
      var viewWidth = overlayView.bounds.size.width
      var viewHeight = overlayView.bounds.size.height
      var originX: CGFloat = 0
      var originY: CGFloat = 0

      if viewWidth / viewHeight > imageSize.width / imageSize.height {
        viewHeight = imageSize.height / imageSize.width  * overlayView.bounds.size.width
        originY = (overlayView.bounds.size.height - viewHeight) / 2
      } else {
        viewWidth = imageSize.width / imageSize.height * overlayView.bounds.size.height
        originX = (overlayView.bounds.size.width - viewWidth) / 2
      }

      var convertedRect = detection.boundingBox
        .applying(CGAffineTransform(scaleX: viewWidth / imageSize.width, y: viewHeight / imageSize.height))
        .applying(CGAffineTransform(translationX: originX, y: originY))

      if convertedRect.origin.x < 0 && convertedRect.origin.x + convertedRect.size.width > edgeOffset {
        convertedRect.size.width += (convertedRect.origin.x - edgeOffset)
        convertedRect.origin.x = edgeOffset
      }

      if convertedRect.origin.y < 0 && convertedRect.origin.y + convertedRect.size.height > edgeOffset {
        convertedRect.size.height += (convertedRect.origin.y - edgeOffset)
        convertedRect.origin.y = edgeOffset
      }

      if convertedRect.maxY > overlayView.bounds.maxY {
        convertedRect.size.height = overlayView.bounds.maxY - convertedRect.origin.y - edgeOffset
      }

      if convertedRect.maxX > overlayView.bounds.maxX {
        convertedRect.size.width = overlayView.bounds.maxX - convertedRect.origin.x - edgeOffset
      }

      let confidenceValue = Int(category.score * 100.0)
      let string = "\(category.categoryName ?? "") (\(confidenceValue)%) "

      let displayColor = ovelayColor

      let size = string.size(withAttributes: [.font: displayFont])

      let objectOverlay = ObjectOverlay(name: string, borderRect: convertedRect, nameStringSize: size, color: displayColor, font: displayFont)

      objectOverlays.append(objectOverlay)
    }

    // Hands off drawing to the OverlayView
    draw(objectOverlays: objectOverlays)

  }

  /** Calls methods to update overlay view with detected bounding boxes and class names.
   */
  private func draw(objectOverlays: [ObjectOverlay]) {

    self.overlayView.objectOverlays = objectOverlays
    self.overlayView.setNeedsDisplay()
  }
}

// MARK: UIImagePickerControllerDelegate, UINavigationControllerDelegate
extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    picker.dismiss(animated: true)
    imageEmptyLabel.isHidden = true
    if info[.mediaType] as? String == UTType.movie.identifier {
      guard let mediaURL = info[.mediaURL] as? URL else { return }
      if runingModel == .image {
        runingModel = .video
      }
      processVideo(url: mediaURL)
    } else {
      guard let image = info[.originalImage] as? UIImage else { return }
      if runingModel == .video {
        runingModel = .image
      }
      removePlayerViewController()
      previewView.image = image
      // Pass the uiimage to mediapipe
      let result = faceDetectorHelper?.detect(image: image)
      // Display results by handing off to the InferenceViewController.
      inferenceViewController?.faceDetectorHelperResult = result
      DispatchQueue.main.async {
        self.inferenceViewController?.updateData()
        self.drawAfterPerformingCalculations(onDetections: result?.faceDetectorResult?.detections ?? [], withImageSize: image.size)
      }
    }
  }
}

// MARK: CameraFeedManagerDelegate Methods
extension ViewController: CameraFeedManagerDelegate {

  func didOutput(pixelBuffer: CVPixelBuffer) {
    // Make sure the model will not run too often, making the results changing quickly and hard to
    // read.
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    guard (currentTimeMs - previousInferenceTimeMs) >= delayBetweenInferencesMs && !isProcess else { return }
    previousInferenceTimeMs = currentTimeMs

    // Pass the pixel buffer to mediapipe
    isProcess = true
    let result = faceDetectorHelper?.detect(videoFrame: pixelBuffer, timeStamps: Int(currentTimeMs))
    isProcess = false
    // Display results by handing off to the InferenceViewController.
    inferenceViewController?.faceDetectorHelperResult = result

    DispatchQueue.main.async {
      self.inferenceViewController?.updateData()
      if self.runningModelTabbar.selectedItem == self.cameraTabbarItem {
        self.drawAfterPerformingCalculations(onDetections: result?.faceDetectorResult?.detections ?? [], withImageSize: CVImageBufferGetDisplaySize(pixelBuffer))
      }
    }
  }

  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {

    // Updates the UI when session is interupted.
    if resumeManually {
      self.resumeButton.isHidden = false
    } else {
      self.cameraUnavailableLabel.isHidden = false
    }
  }

  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    if !self.cameraUnavailableLabel.isHidden {
      self.cameraUnavailableLabel.isHidden = true
    }

    if !self.resumeButton.isHidden {
      self.resumeButton.isHidden = true
    }
  }

  func sessionRunTimeErrorOccured() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    self.resumeButton.isHidden = false
    previewView.shouldUseClipboardImage = true
  }

  func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)

    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)

    present(alertController, animated: true, completion: nil)

    previewView.shouldUseClipboardImage = true
  }

  func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed", message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

    self.present(alert, animated: true)
    previewView.shouldUseClipboardImage = true
  }
}

// MARK: InferenceViewControllerDelegate Methods
extension ViewController: InferenceViewControllerDelegate {
  func viewController(
    _ viewController: InferenceViewController,
    needPerformActions action: InferenceViewController.Action
  ) {
    var isModelNeedsRefresh = false
    switch action {
    case .changeMinDetectionConfidence(let minDetectionConfidence):
      if self.minDetectionConfidence != minDetectionConfidence {
        isModelNeedsRefresh = true
      }
      self.minDetectionConfidence = minDetectionConfidence
    case .changeMinSuppressionThreshold(let minSuppressionThreshold):
      if self.minSuppressionThreshold != minSuppressionThreshold {
        isModelNeedsRefresh = true
      }
      self.minSuppressionThreshold = minSuppressionThreshold
    case .changeBottomSheetViewBottomSpace(let isExpand):
      bottomSheetViewBottomSpace.constant = isExpand ? 0 : -inferenceBottomHeight + expandButtonHeight
      UIView.animate(withDuration: 0.3) {
        self.view.layoutSubviews()
      }
    }
    if isModelNeedsRefresh {
      faceDetectorHelper = FaceDetectorHelper(
        modelPath: modelPath,
        minDetectionConfidence: minDetectionConfidence,
        minSuppressionThreshold: minSuppressionThreshold,
        runningModel: runingModel
      )
    }
  }
}

// MARK: UITabBarDelegate
extension ViewController: UITabBarDelegate {
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    switch item {
    case cameraTabbarItem:
      if runingModel == .image {
        runingModel = .video
      }
      removePlayerViewController()
#if !targetEnvironment(simulator)
      cameraCapture.checkCameraConfigurationAndStartSession()
#endif
      previewView.shouldUseClipboardImage = false
      addImageButton.isHidden = true
      imageEmptyLabel.isHidden = true
    case photoTabbarItem:
#if !targetEnvironment(simulator)
      cameraCapture.stopSession()
#endif
      previewView.shouldUseClipboardImage = true
      addImageButton.isHidden = false
      if previewView.image == nil || playerViewController.parent != self {
        imageEmptyLabel.isHidden = false
      }
    default:
      break
    }
    overlayView.objectOverlays = []
    overlayView.setNeedsDisplay()
  }
}

import VideoToolbox

extension UIImage {
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        guard let cgImage = cgImage else {
            return nil
        }

        self.init(cgImage: cgImage)
    }
}