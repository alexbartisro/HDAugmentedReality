//
//  RadarMapView.swift
//  HDAugmentedRealityDemo
//
//  Created by Danijel Huis on 15/07/2019.
//  Copyright © 2019 Danijel Huis. All rights reserved.
//
import UIKit
import MapKit
import SceneKit

/**
 RadarMapView consists of:
    - MKMapView showing annotations
    - ring around map that shows out of bounds annotations (indicators)
    - map zoom in/out and radar shrink/expand buttons
 
 RadarMapView gets annotations and all other data via ARAccessory delegate. Intended to be used with ARViewController.
 
 Usage:
    - RadarMapView must have height constraint in order to resize/shrink properly.
    - use startMode and trackingMode properties to adjust how map zoom/tracking behaves on start and later on.
    - use configuration property to customize.
 
 Internal note: Problems with MKMapView:
 - setting anything on MKMapCamera will cancel current map annimation, e.g. setting heading will cause map to jump to location instead of smoothly animate.
 - setting heading everytime it changes will disable user interaction with map and cancel all animations.
 */
open class RadarMapView: UIView, ARAccessory, MKMapViewDelegate
{
    public struct Configuration
    {
        /// Image for annotations that are shown on the map
        public var annotationImage = UIImage(named: "radarAnnotation", in: Bundle(for: RadarMapView.self), compatibleWith: nil)
        /// Image for user indicator that is shown on the map
        public var userAnnotationImage = UIImage(named: "userRadarAnnotation", in: Bundle(for: RadarMapView.self), compatibleWith: nil)
        /// Use it to set anchor point for your userAnnotationImage. This is where you center is on the image, in default image its on 201st pixel, image height is 240.
        public var userAnnotationAnchorPoint = CGPoint(x: 0.5, y: 201/240)
        /// Size of indicator on the ring that shows out of bounds annotations.
        public var indicatorSize: CGFloat = 8
        /// Image for indicators on the ring that shows out of bounds annotations.
        public var indicatorImage = UIImage(named: "radarAnnotation", in: Bundle(for: RadarMapView.self), compatibleWith: nil)
        /// Image for user indicator on the ring that shows out of bounds annotations.
        public var userIndicatorImage = UIImage(named: "userIndicator", in: Bundle(for: RadarMapView.self), compatibleWith: nil)
        /// Determines how much RadarMapView expands.
        public var radarSizeRatio: CGFloat = 1.75
    }
    
    //===== Public
    /// Defines map position and zoom at start.
    open var startMode: RadarStartMode = .centerUser(span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    /// Defines map position and zoom when user location changes.
    open var trackingMode: RadarTrackingMode = .centerUserWhenNearBorder(span: nil)
    /// Use it to configure and customize your radar.
    open var configuration: Configuration = Configuration()
    
    //===== IB
    @IBOutlet weak private(set) public var mapViewContainer: UIView!
    @IBOutlet weak private(set) public var mapView: MKMapView!
    @IBOutlet weak private(set) public var indicatorContainerView: UIView!
    @IBOutlet weak private(set) public var resizeButton: UIButton!
    @IBOutlet weak private(set) public var zoomInButton: UIButton!
    @IBOutlet weak private(set) public var zoomOutButton: UIButton!

    //===== Private
    private var isFirstZoom = true
    private var isReadyToReload = false
    private var radarAnnotations: [ARAnnotation] = []
    private var userRadarAnnotation: ARAnnotation?
    private weak var userRadarAnnotationView: UserRadarAnnotationView?
    private var indicatorViewsDictionary: [ARAnnotation : UIImageView] = [:]
    override open var bounds: CGRect { didSet { self.layoutUi() } }

    //==========================================================================================================================================================
    // MARK:                                                       Init
    //==========================================================================================================================================================
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        self.addSubviewFromNib()
        self.loadUi()
        self.bindUi()
        self.styleUi()
        self.layoutUi()
    }
    
    required public init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        self.addSubviewFromNib()
    }
    
    override open func awakeFromNib()
    {
        super.awakeFromNib()
        self.loadUi()
        self.bindUi()
        self.styleUi()
        self.layoutUi()
    }
    
    //==========================================================================================================================================================
    // MARK:                                                       UI
    //==========================================================================================================================================================
    func loadUi()
    {
        self.isReadyToReload = true

    }
    
    func bindUi()
    {
        self.bindResizeButton()
    }
    
    func styleUi()
    {
        self.backgroundColor = .clear
    }
    
    func layoutUi()
    {
        self.mapView.setNeedsLayout()
        self.mapView.layoutIfNeeded()
        self.mapView.layer.cornerRadius = self.mapView.bounds.size.width / 2.0
        
        self.indicatorContainerView.setNeedsLayout()
        self.indicatorContainerView.layoutIfNeeded()
        self.indicatorContainerView.layer.cornerRadius = self.indicatorContainerView.bounds.size.width / 2.0
    }

    //==========================================================================================================================================================
    // MARK:                                                    Reload
    //==========================================================================================================================================================
    public func reload(reloadType: ARViewController.ReloadType, status: ARStatus, presenter: ARPresenter)
    {
        guard self.isReadyToReload, let location = status.userLocation else { return }
        var didChangeAnnotations = false
        
        //===== Add/remove radar annotations if annotations changed
        if reloadType == .annotationsChanged || self.radarAnnotations.count != presenter.annotations.count
        {
            self.radarAnnotations = presenter.annotations
            // Remove everything except the user annotation
            self.mapView.removeAnnotations(self.mapView.annotations.filter { $0 !== self.userRadarAnnotation })
            self.mapView.addAnnotations(self.radarAnnotations)
            didChangeAnnotations = true
        }
        
        //===== Add/remove user map annotation when user location changes
        if [.reloadLocationChanged, .userLocationChanged].contains(reloadType) || self.userRadarAnnotation == nil
        {
            // It doesn't work if we just update annotation's coordinate, we have to remove it and add again.
            if let userRadarAnnotation = self.userRadarAnnotation
            {
                self.mapView.removeAnnotation(userRadarAnnotation)
                self.userRadarAnnotation = nil
            }
            
            if let newUserRadarAnnotation = ARAnnotation(identifier: "userRadarAnnotation", title: nil, location: location)
            {
                self.mapView.addAnnotation(newUserRadarAnnotation)
                self.userRadarAnnotation = newUserRadarAnnotation
            }
            didChangeAnnotations = true
        }
        
        //===== Track user (map position and zoom)
        if self.isFirstZoom || [.reloadLocationChanged, .userLocationChanged].contains(reloadType)
        {
            let isFirstZoom = self.isFirstZoom
            self.isFirstZoom = false
            
            if isFirstZoom
            {
                if case .centerUser(let span) = self.startMode
                {
                    let region = MKCoordinateRegion(center: location.coordinate, span: span)
                    self.mapView.setRegion(self.mapView.regionThatFits(region), animated: false)
                }
                else if case .fitAnnotations = self.startMode
                {
                    self.setRegionToAnntations(animated: false)
                }
            }
            else
            {
                if case .centerUserAlways(let trackingModeSpan) = self.trackingMode
                {
                    let span = trackingModeSpan ?? self.mapView.region.span
                    let region = MKCoordinateRegion(center: location.coordinate, span: span)
                    self.mapView.setRegion(self.mapView.regionThatFits(region), animated: true)
                }
                else if case .centerUserWhenNearBorder(let trackingModeSpan) = self.trackingMode
                {
                    if self.isUserRadarAnnotationNearOrOverBorder
                    {
                        let span = trackingModeSpan ?? self.mapView.region.span
                        let region = MKCoordinateRegion(center: location.coordinate, span: span)
                        self.mapView.setRegion(self.mapView.regionThatFits(region), animated: true)
                    }
                }
            }
        }
        
        //===== Heading
        self.userRadarAnnotationView?.heading = status.heading
        
        //===== Indicators
        if didChangeAnnotations
        {
            self.updateIndicators()
        }
  }
    
    //==========================================================================================================================================================
    // MARK:                                                    MKMapViewDelegate
    //==========================================================================================================================================================
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView?
    {
        // User annotation
        if annotation === self.userRadarAnnotation
        {
            let reuseIdentifier = "userRadarAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as! UserRadarAnnotationView?) ?? UserRadarAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            view.displayPriority = .required
            view.canShowCallout = false
            view.isSelected = true  // Keeps it above other annotations (hopefully)
            view.imageView?.image = self.configuration.userAnnotationImage
            view.imageView?.layer.anchorPoint = self.configuration.userAnnotationAnchorPoint
            view.frame.size = self.configuration.userAnnotationImage?.size ?? CGSize(width: 100, height: 100)
            self.userRadarAnnotationView = view

            return view
        }
        // Other annotations
        else
        {
            let reuseIdentifier = "radarAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            view.displayPriority = .required
            view.canShowCallout = false
            view.image = self.configuration.annotationImage
            return view
        }
    }
    
    public func mapViewDidChangeVisibleRegion(_ mapView: MKMapView)
    {
        self.updateIndicators()
    }
    
    //==========================================================================================================================================================
    // MARK:                                                    Indicators
    //==========================================================================================================================================================
    
    /**
     Updates indicators position.
     */
    private func updateIndicators()
    {
         let mapRadius = Double(self.mapView.frame.size.width) / 2
         let mapCenter = simd_double2(x: mapRadius, y: mapRadius)

        var newIndicatorViewsDictionary: [ARAnnotation : UIImageView] = [:]
        let allViews = Set(self.indicatorContainerView.subviews)
        var usedViews: Set<UIView> = Set()
        let indicatorSize = self.configuration.indicatorSize
        
        for annotation in self.mapView.annotations
        {
            guard let arAnnotation = annotation as? ARAnnotation else { continue }
            let isUserAnnotation = arAnnotation === self.userRadarAnnotation
            let existingIndicatorView = self.indicatorViewsDictionary[arAnnotation]
            if let existingIndicatorView = existingIndicatorView { newIndicatorViewsDictionary[arAnnotation] = existingIndicatorView  }
            
            // Calculate point on circumference
            let annotationCenterCGPoint = self.mapView.convert(annotation.coordinate, toPointTo: self.mapView)
            let annotationCenter = simd_double2(x: Double(annotationCenterCGPoint.x) , y: Double(annotationCenterCGPoint.y))
            let centerToAnnotationVector = annotationCenter - mapCenter
            let pointOnCircumference = mapCenter + simd_normalize(centerToAnnotationVector) * (mapRadius + 1.5)
            if simd_length(centerToAnnotationVector) < mapRadius { continue } // It is not added to usedViews so it will be removed from superView

            // Create indicator view if not reusing old view.
            let indicatorView: UIImageView
            if let existingIndicatorView = existingIndicatorView { indicatorView = existingIndicatorView }
            else
            {
                let newIndicatorView = UIImageView()
                newIndicatorView.image = isUserAnnotation ? self.configuration.userIndicatorImage : self.configuration.indicatorImage
                // x,y not important her, it is set after.
                newIndicatorView.frame = CGRect(x: 0, y: 0, width: indicatorSize, height: indicatorSize)
                newIndicatorViewsDictionary[arAnnotation] = newIndicatorView
                indicatorView = newIndicatorView
            }
            
            indicatorView.center = self.indicatorContainerView.convert(CGPoint(x: pointOnCircumference.x, y: pointOnCircumference.y), from: self.mapView)
            self.indicatorContainerView.insertSubview(indicatorView, at: 0)
            if isUserAnnotation { self.indicatorContainerView.bringSubviewToFront(indicatorView) }
            
            usedViews.insert(indicatorView)
        }
        
        // Remove all views that are not used
        let unusedViews = allViews.subtracting(usedViews)
        for view in unusedViews { view.removeFromSuperview() }
        
        // Update newIndicatorViewsDictionary (also removes unused items)
        self.indicatorViewsDictionary = newIndicatorViewsDictionary
    }
    
    /**
     Returns true if user annotation is near or over border of the map.
     */
    private var isUserRadarAnnotationNearOrOverBorder: Bool
    {
        let mapRadius = Double(self.mapView.frame.size.width) / 2
        guard let annotation = self.userRadarAnnotation, mapRadius > 30 else { return false }

        let threshold = mapRadius * 0.4
        let mapCenter = simd_double2(x: mapRadius, y: mapRadius)
        let annotationCenterCGPoint = self.mapView.convert(annotation.coordinate, toPointTo: self.mapView)
        let annotationCenter = simd_double2(x: Double(annotationCenterCGPoint.x) , y: Double(annotationCenterCGPoint.y))
        let centerToAnnotationVector = annotationCenter - mapCenter
        
        if simd_length(centerToAnnotationVector) > (mapRadius - threshold)
        {
            return true
        }
        
        return false
    }
    
    //==========================================================================================================================================================
    // MARK:                                                    Utility
    //==========================================================================================================================================================
   
    /**
     Zooms map by given factor.
     */
    open func zoomMap(by factor: Double, animated: Bool)
    {
        var region: MKCoordinateRegion = self.mapView.region
        var span: MKCoordinateSpan = self.mapView.region.span
        span.latitudeDelta *= factor
        span.longitudeDelta *= factor
        region.span = span
        self.mapView.setRegion(region, animated: animated)
    }
    
    /**
     Zooms map to fit all annotations (considering rounded map).
     */
    open func setRegionToAnntations(animated: Bool)
    {
        var zoomRect = MKMapRect.null
        let edgePadding = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)    // Maybe make ratio of map size?
        for annotation in self.mapView.annotations
        {
            let annotationPoint = MKMapPoint(annotation.coordinate)
            let annotationRect = MKMapRect(x: annotationPoint.x, y: annotationPoint.y, width: 0.1, height: 0.1)
            zoomRect = zoomRect.union(annotationRect)
        }
        
        if zoomRect.width > 0 || zoomRect.height > 0 { self.mapView.setVisibleMapRect(zoomRect, edgePadding: edgePadding, animated: animated) }
    }
    
    private var isResized: Bool = false
    private var heightBeforeResizing: CGFloat?
    private func resizeRadar()
    {
        if self.heightBeforeResizing == nil { self.heightBeforeResizing = self.frame.size.height }
        guard let heightConstraint = self.findConstraint(attribute: .height), let heightBeforeResizing = self.heightBeforeResizing else
        {
            print("Cannot resize, RadarMapView must have height constraint.")
            return
        }
        self.isResized = !self.isResized
        
        heightConstraint.constant = self.isResized ? heightBeforeResizing * self.configuration.radarSizeRatio : heightBeforeResizing

        UIView.animate(withDuration: 1/3, animations:
        {
            self.superview?.layoutIfNeeded()
            self.bindResizeButton()
            self.updateIndicators()
        })
        {
            (finished) in
            
            self.mapView.setNeedsLayout()   // Needed because of legal label.
        }
    }
    
    private func bindResizeButton()
    {
        self.resizeButton.isSelected = self.isResized
    }

    //==========================================================================================================================================================
    // MARK:                                                    User interaction
    //==========================================================================================================================================================
    @IBAction func sizeButtonTapped(_ sender: Any)
    {
        self.resizeRadar()
    }
    
    @IBAction func zoomInButtonTapped(_ sender: Any)
    {
        self.zoomMap(by: 75/100, animated: false)
    }
    
    @IBAction func zoomOutButtonTapped(_ sender: Any)
    {
        self.zoomMap(by: 100/75, animated: false)
    }
}

//==========================================================================================================================================================
// MARK:                                                    Helper classes
//==========================================================================================================================================================
/**
 Compass style MKAnnotationView.
 */
open class UserRadarAnnotationView: MKAnnotationView
{
    open var imageView: UIImageView?
    open var heading: Double = 0 { didSet { self.layoutUi() } }
    
    public override init(annotation: MKAnnotation?, reuseIdentifier: String?)
    {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.loadUi()
    }
    
    required public init?(coder aDecoder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
    
    open func loadUi()
    {
        self.frame = CGRect(x: 0, y: 0, width: 100, height: 100) // Doesn't matter, it is set in RadarMapView.

        self.imageView?.removeFromSuperview()
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(imageView)
        imageView.pinToSuperview(leading: 0, trailing: 0, top: 0, bottom: 0, width: nil, height: nil)
        self.imageView = imageView
    }
    
    open func layoutUi()
    {
        self.imageView?.transform = CGAffineTransform.identity.rotated(by: CGFloat(self.heading.toRadians))
    }
}

public enum RadarStartMode
{
    /// Centers on user
    case centerUser(span: MKCoordinateSpan)
    /// Fits annotations
    case fitAnnotations
}

public enum RadarTrackingMode
{
    case none
    /// Centers on user whenever location change is detected. Use span if you want to force zoom/span level.
    case centerUserAlways(span: MKCoordinateSpan?)
    /// Centers on user when its annotation comes near map border. Use span if you want to force zoom/span level.
    case centerUserWhenNearBorder(span: MKCoordinateSpan?)
}

/**
 MKMapView subclass that moves legal label to center (horizontally).
 */
class LegalMapView: MKMapView
{
    private var isLayoutingLegalLabel = false
    override func layoutSubviews()
    {
        super.layoutSubviews()
        guard !self.isLayoutingLegalLabel else { return }   // To prevent layout loops.
        
        self.isLayoutingLegalLabel = true
        for subview in self.subviews
        {
            if "\(type(of: subview))" == "MKAttributionLabel"   //MKAttributionLabel, _MKMapContentView
            {
                subview.layer.cornerRadius = subview.frame.size.height * 0.5
                subview.center.x = self.frame.size.width / 2
            }
        }
        self.isLayoutingLegalLabel = false
    }
}
