//
//  FastttCamera.m
//  FastttCamera
//
//  Created by Laura Skelton on 2/5/15.
//
//

#import <AVFoundation/AVFoundation.h>

#import "FastttCamera.h"
#import "IFTTTDeviceOrientation.h"
#import "UIImage+FastttCamera.h"
#import "AVCaptureDevice+FastttCamera.h"
#import "FastttFocus.h"
#import "FastttZoom.h"
#import "FastttCapturedImage+Process.h"

@interface FastttCamera () <FastttFocusDelegate, FastttZoomDelegate>

@property (nonatomic, strong) IFTTTDeviceOrientation *deviceOrientation;
@property (nonatomic, strong) FastttFocus *fastFocus;
@property (nonatomic, strong) FastttZoom *fastZoom;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property (nonatomic, assign) BOOL deviceAuthorized;
@property (nonatomic, assign) BOOL isCapturingImage;
// 新增线程安全属性
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) BOOL isTearingDown;
@end

@implementation FastttCamera

@synthesize delegate = _delegate,
            returnsRotatedPreview = _returnsRotatedPreview,
            showsFocusView = _showsFocusView,
            maxScaledDimension = _maxScaledDimension,
            normalizesImageOrientations = _normalizesImageOrientations,
            cropsImageToVisibleAspectRatio = _cropsImageToVisibleAspectRatio,
            interfaceRotatesWithOrientation = _interfaceRotatesWithOrientation,
            fixedInterfaceOrientation = _fixedInterfaceOrientation,
            handlesTapFocus = _handlesTapFocus,
            handlesZoom = _handlesZoom,
            maxZoomFactor = _maxZoomFactor,
            showsZoomView = _showsZoomView,
            gestureView = _gestureView,
            gestureDelegate = _gestureDelegate,
            scalesImage = _scalesImage,
            cameraDevice = _cameraDevice,
            cameraFlashMode = _cameraFlashMode,
            cameraTorchMode = _cameraTorchMode;

- (instancetype)init
{
    if ((self = [super init])) {
        // 关键修改点1：创建专用串行队列
        _sessionQueue = dispatch_queue_create("com.fastttcamera.session", DISPATCH_QUEUE_SERIAL);
        [self _setupCaptureSession];
        
        _handlesTapFocus = YES;
        _showsFocusView = YES;
        _handlesZoom = YES;
        _showsZoomView = YES;
        _cropsImageToVisibleAspectRatio = YES;
        _scalesImage = YES;
        _maxScaledDimension = 0.f;
        _maxZoomFactor = 1.f;
        _normalizesImageOrientations = YES;
        _returnsRotatedPreview = YES;
        _interfaceRotatesWithOrientation = YES;
        _fixedInterfaceOrientation = UIDeviceOrientationPortrait;
        _cameraDevice = FastttCameraDeviceRear;
        _cameraFlashMode = FastttCameraFlashModeOff;
        _cameraTorchMode = FastttCameraTorchModeOff;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    
    return self;
}

- (void)dealloc
{
    _fastFocus = nil;
    _fastZoom = nil;
    
    if (_sessionQueue) {
            if (dispatch_queue_get_specific(_sessionQueue, "FastttCameraSessionQueue")) {
                [self _performTeardown];
            } else {
                dispatch_sync(_sessionQueue, ^{
                    [self _performTeardown];
                });
            }
        }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_previewLayer) {
            [_previewLayer removeFromSuperlayer];
            _previewLayer = nil;
        }
    
    
}

#pragma mark - View Events

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self _insertPreviewLayer];
    
    UIView *viewForGestures = self.view;
    
    if (self.gestureView) {
        viewForGestures = self.gestureView;
    }
    
    _fastFocus = [FastttFocus fastttFocusWithView:viewForGestures gestureDelegate:self.gestureDelegate];
    self.fastFocus.delegate = self;
    
    if (!self.handlesTapFocus) {
        self.fastFocus.detectsTaps = NO;
    }
    
    _fastZoom = [FastttZoom fastttZoomWithView:viewForGestures gestureDelegate:self.gestureDelegate];
    self.fastZoom.delegate = self;
    
    if (!self.handlesZoom) {
        self.fastZoom.detectsPinch = NO;
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self startRunning];
    
    [self _insertPreviewLayer];
    
    [self _setPreviewVideoOrientation];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    [self stopRunning];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _previewLayer.frame = self.view.layer.bounds;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    if (!self.session) {
        [self _setupCaptureSession];
    };
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    if (self.isViewLoaded && self.view.window) {
        [self startRunning];
        [self _insertPreviewLayer];
        [self _setPreviewVideoOrientation];
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    [self stopRunning];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self _teardownCaptureSession];
}

#pragma mark - Autorotation

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [self _setPreviewVideoOrientation];
}

#pragma mark - Taking a Photo

- (BOOL)isReadyToCapturePhoto
{
    @synchronized (self) {
        return !_isCapturingImage && !_isTearingDown;
    }
}

- (void)takePicture
{
    if (!_deviceAuthorized) {
        return;
    }
    
    [self _takePhoto];
}

- (void)cancelImageProcessing
{
    if (_isCapturingImage) {
        _isCapturingImage = NO;
    }
}

#pragma mark - Processing a Photo

- (void)processImage:(UIImage *)image withMaxDimension:(CGFloat)maxDimension
{
    [self _processImage:image withCropRect:CGRectNull maxDimension:maxDimension fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
}

- (void)processImage:(UIImage *)image withCropRect:(CGRect)cropRect
{
    [self _processImage:image withCropRect:cropRect maxDimension:0.f fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
}

- (void)processImage:(UIImage *)image withCropRect:(CGRect)cropRect maxDimension:(CGFloat)maxDimension
{
    [self _processImage:image withCropRect:cropRect maxDimension:maxDimension fromCamera:NO needsPreviewRotation:NO previewOrientation:UIDeviceOrientationUnknown];
}

#pragma mark - Camera State

+ (BOOL)isPointFocusAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isPointFocusAvailableForCameraDevice:cameraDevice];
}

- (BOOL)focusAtPoint:(CGPoint)touchPoint
{
    CGPoint pointOfInterest = [self _focusPointOfInterestForTouchPoint:touchPoint];
    
    return [self _focusAtPointOfInterest:pointOfInterest];
}

- (BOOL)zoomToScale:(CGFloat)scale
{
    return [[self _currentCameraDevice] zoomToScale:scale];
}

- (BOOL)isFlashAvailableForCurrentDevice
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([device isFlashModeSupported:AVCaptureFlashModeOn]) {
        return YES;
    }
    
    return NO;
}

+ (BOOL)isFlashAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isFlashAvailableForCameraDevice:cameraDevice];
}

- (BOOL)isTorchAvailableForCurrentDevice
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([device isTorchModeSupported:AVCaptureTorchModeOn]) {
        return YES;
    }
    
    return NO;
}

+ (BOOL)isTorchAvailableForCameraDevice:(FastttCameraDevice)cameraDevice
{
    return [AVCaptureDevice isTorchAvailableForCameraDevice:cameraDevice];
}

+ (BOOL)isCameraDeviceAvailable:(FastttCameraDevice)cameraDevice
{
    return ([AVCaptureDevice cameraDevice:cameraDevice] != nil);
}

- (void)setCameraDevice:(FastttCameraDevice)cameraDevice
{
    AVCaptureDevice *device = [AVCaptureDevice cameraDevice:cameraDevice];
    
    if (!device) {
        return;
    }
    
    if (_cameraDevice != cameraDevice) {
        _cameraDevice = cameraDevice;
        
        AVCaptureDeviceInput *oldInput = [_session.inputs lastObject];
        AVCaptureDeviceInput *newInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
        
        [_session beginConfiguration];
        [_session removeInput:oldInput];
        [_session addInput:newInput];
        [_session commitConfiguration];
    }
    
    [self setCameraFlashMode:_cameraFlashMode];
    [self _resetZoom];
}

- (void)setCameraFlashMode:(FastttCameraFlashMode)cameraFlashMode
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([AVCaptureDevice isFlashAvailableForCameraDevice:self.cameraDevice]) {
        _cameraFlashMode = cameraFlashMode;
        [device setCameraFlashMode:cameraFlashMode];
        return;
    }
    
    _cameraFlashMode = FastttCameraFlashModeOff;
}

- (void)setCameraTorchMode:(FastttCameraTorchMode)cameraTorchMode
{
    AVCaptureDevice *device = [self _currentCameraDevice];
    
    if ([AVCaptureDevice isTorchAvailableForCameraDevice:self.cameraDevice]) {
        _cameraTorchMode = cameraTorchMode;
        [device setCameraTorchMode:cameraTorchMode];
        return;
    }
    
    _cameraTorchMode = FastttCameraTorchModeOff;
}

#pragma mark - Capture Session Management

- (void)startRunning
{
    // 关键修改点2：线程安全启动
        __weak typeof(self) weakSelf = self;
        dispatch_async(_sessionQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isTearingDown || !strongSelf.session) return;
            
            if (![strongSelf.session isRunning]) {
                [strongSelf.session startRunning];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([strongSelf.delegate respondsToSelector:@selector(cameraSessionDidStart)]) {
                        [strongSelf.delegate cameraSessionDidStart];
                    }
                });
            }
        });
}

- (void)stopRunning
{
    __weak typeof(self) weakSelf = self;
        dispatch_async(_sessionQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.session) return;
            
            if ([strongSelf.session isRunning]) {
                [strongSelf.session stopRunning];
            }
        });
}

- (void)_insertPreviewLayer
{
    if (!_deviceAuthorized) {
        return;
    }
    
    if ([_previewLayer superlayer] == [self.view layer]
        && [_previewLayer session] == _session) {
        return;
    }
    
    [self _removePreviewLayer];
    
    CALayer *rootLayer = [self.view layer];
    rootLayer.masksToBounds = YES;
    
    _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    _previewLayer.frame = rootLayer.bounds;
    
    [rootLayer insertSublayer:_previewLayer atIndex:0];
}

- (void)_removePreviewLayer
{
    [_previewLayer removeFromSuperlayer];
    _previewLayer = nil;
}

- (void)_setupCaptureSession
{
    if (_session) return;
    
    // 关键修改点3：授权检查移到队列内
    __weak typeof(self) weakSelf = self;
    dispatch_async(_sessionQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isTearingDown) return;
        
#if !TARGET_IPHONE_SIMULATOR
        [strongSelf _checkDeviceAuthorizationWithCompletion:^(BOOL isAuthorized) {
            strongSelf.deviceAuthorized = isAuthorized;
#else
            strongSelf.deviceAuthorized = YES;
#endif
            if (!strongSelf.deviceAuthorized) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([strongSelf.delegate respondsToSelector:@selector(userDeniedCameraPermissionsForCameraController:)]) {
                        [strongSelf.delegate userDeniedCameraPermissionsForCameraController:strongSelf];
                    }
                });
                return;
            }
            
            dispatch_async(strongSelf.sessionQueue, ^{
                if (strongSelf.isTearingDown) return;
                
                strongSelf.session = [AVCaptureSession new];
                strongSelf.session.sessionPreset = AVCaptureSessionPresetPhoto;
                
                AVCaptureDevice *device = [AVCaptureDevice cameraDevice:strongSelf.cameraDevice];
                if (!device) device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
                
                NSError *error = nil;
                AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
                
                if (input && [strongSelf.session canAddInput:input]) {
                    [strongSelf.session addInput:input];
                } else {
                    NSLog(@"Error setting up camera input: %@", error.localizedDescription);
                    return;
                }
                
                strongSelf.stillImageOutput = [AVCaptureStillImageOutput new];
                strongSelf.stillImageOutput.outputSettings = @{AVVideoCodecKey: AVVideoCodecJPEG};
                
                if ([strongSelf.session canAddOutput:strongSelf.stillImageOutput]) {
                    [strongSelf.session addOutput:strongSelf.stillImageOutput];
                }
                
                strongSelf.deviceOrientation = [IFTTTDeviceOrientation new];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf _insertPreviewLayer];
                    [strongSelf _setPreviewVideoOrientation];
                });
                
                [strongSelf startRunning];
            });
#if !TARGET_IPHONE_SIMULATOR
        }];
#endif
    });
}


//- (void)_teardownCaptureSession
//{
//    self.isTearingDown = YES;
//        __weak typeof(self) weakSelf = self;
//        dispatch_async(_sessionQueue, ^{
//            __strong typeof(weakSelf) strongSelf = weakSelf;
//            if (!strongSelf || !strongSelf.session) {
//                strongSelf.isTearingDown = NO;
//                return;
//            }
//            
//            if ([strongSelf.session isRunning]) {
//                [strongSelf.session stopRunning];
//            }
//            
//            for (AVCaptureInput *input in strongSelf.session.inputs) {
//                [strongSelf.session removeInput:input];
//            }
//            
//            for (AVCaptureOutput *output in strongSelf.session.outputs) {
//                [strongSelf.session removeOutput:output];
//            }
//            
//            strongSelf.session = nil;
//            strongSelf.stillImageOutput = nil;
//            
//            dispatch_async(dispatch_get_main_queue(), ^{
//                [strongSelf _removePreviewLayer];
//            });
//            
//            strongSelf.isTearingDown = NO;
//        });
//}

- (void)_teardownCaptureSession {
    self.isTearingDown = YES;
    
    if (dispatch_queue_get_specific(_sessionQueue, "FastttCameraSessionQueue")) {
        [self _performTeardown];
    } else {
        dispatch_sync(_sessionQueue, ^{
            [self _performTeardown];
        });
    }
}

- (void)_performTeardown {
    if (!_session) {
        self.isTearingDown = NO;
        return;
    }
    
    if ([_session isRunning]) {
        [_session stopRunning];
    }
    
    // 安全移除输入输出
    NSArray<AVCaptureInput *> *inputs = [_session.inputs copy];
    for (AVCaptureInput *input in inputs) {
        [_session removeInput:input];
    }
    
    NSArray<AVCaptureOutput *> *outputs = [_session.outputs copy];
    for (AVCaptureOutput *output in outputs) {
        [_session removeOutput:output];
    }
    
    _session = nil;
    _stillImageOutput = nil;
    
    [self _removePreviewLayer];
    
    self.isTearingDown = NO;
}

#pragma mark - Capturing a Photo

- (void)_takePhoto
{
    if (self.isCapturingImage) {
        return;
    }
    self.isCapturingImage = YES;
    
    BOOL needsPreviewRotation = ![self.deviceOrientation deviceOrientationMatchesInterfaceOrientation];
    
    AVCaptureConnection *videoConnection = [self _currentCaptureConnection];
    
    if ([videoConnection isVideoOrientationSupported]) {
        [videoConnection setVideoOrientation:[self _currentCaptureVideoOrientationForDevice]];
    }
    
    if ([videoConnection isVideoMirroringSupported]) {
        [videoConnection setVideoMirrored:(_cameraDevice == FastttCameraDeviceFront)];
    }
    
#if TARGET_IPHONE_SIMULATOR
    [self _insertPreviewLayer];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *fakeImage = [UIImage fastttFakeTestImage];
        [self _processCameraPhoto:fakeImage needsPreviewRotation:needsPreviewRotation previewOrientation:UIDeviceOrientationPortrait];
    });
#else    
    UIDeviceOrientation previewOrientation = [self _currentPreviewDeviceOrientation];

    [_stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection
                                                   completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error)
     {
         if (!imageDataSampleBuffer) {
             return;
         }
         
         if (!self.isCapturingImage) {
             return;
         }
         
         NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];

         if ([self.delegate respondsToSelector:@selector(cameraController:didFinishCapturingImageData:)]) {
             [self.delegate cameraController:self didFinishCapturingImageData:imageData];
         }

         dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
             
             UIImage *image = [UIImage imageWithData:imageData];
             
             [self _processCameraPhoto:image needsPreviewRotation:needsPreviewRotation previewOrientation:previewOrientation];
         });
     }];
#endif
}

#pragma mark - Processing a Photo

- (void)_processCameraPhoto:(UIImage *)image needsPreviewRotation:(BOOL)needsPreviewRotation previewOrientation:(UIDeviceOrientation)previewOrientation
{
    CGRect cropRect = CGRectNull;
    if (self.cropsImageToVisibleAspectRatio) {
        cropRect = [image fastttCropRectFromPreviewLayer:_previewLayer];
    }
    
    [self _processImage:image withCropRect:cropRect maxDimension:self.maxScaledDimension fromCamera:YES needsPreviewRotation:(needsPreviewRotation || !self.interfaceRotatesWithOrientation) previewOrientation:previewOrientation];
}

- (void)_processImage:(UIImage *)image withCropRect:(CGRect)cropRect maxDimension:(CGFloat)maxDimension fromCamera:(BOOL)fromCamera needsPreviewRotation:(BOOL)needsPreviewRotation previewOrientation:(UIDeviceOrientation)previewOrientation
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (fromCamera && !self.isCapturingImage) {
            return;
        }
        
        FastttCapturedImage *capturedImage = [FastttCapturedImage fastttCapturedFullImage:image];
        
        [capturedImage cropToRect:cropRect
                   returnsPreview:(fromCamera && self.returnsRotatedPreview)
             needsPreviewRotation:needsPreviewRotation
           withPreviewOrientation:previewOrientation
                     withCallback:^(FastttCapturedImage *capturedImage){
                         if (fromCamera && !self.isCapturingImage) {
                             return;
                         }
                         if ([self.delegate respondsToSelector:@selector(cameraController:didFinishCapturingImage:)]) {
                             dispatch_async(dispatch_get_main_queue(), ^{
                                 [self.delegate cameraController:self didFinishCapturingImage:capturedImage];
                             });
                         }
                     }];
        
        void (^scaleCallback)(FastttCapturedImage *capturedImage) = ^(FastttCapturedImage *capturedImage) {
            if (fromCamera && !self.isCapturingImage) {
                return;
            }
            if ([self.delegate respondsToSelector:@selector(cameraController:didFinishScalingCapturedImage:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate cameraController:self didFinishScalingCapturedImage:capturedImage];
                });
            }
        };
        
        if (fromCamera && !self.isCapturingImage) {
            return;
        }
        
        if (maxDimension > 0.f) {
            [capturedImage scaleToMaxDimension:maxDimension
                                  withCallback:scaleCallback];
        } else if (fromCamera && self.scalesImage) {
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                            //Run UI Updates
                [capturedImage scaleToSize:self.view.bounds.size withCallback:scaleCallback];
            });
        }
        
        if (fromCamera && !self.isCapturingImage) {
            return;
        }
        
        if (self.normalizesImageOrientations) {
            [capturedImage normalizeWithCallback:^(FastttCapturedImage *capturedImage){
                if (fromCamera && !self.isCapturingImage) {
                    return;
                }
                if ([self.delegate respondsToSelector:@selector(cameraController:didFinishNormalizingCapturedImage:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate cameraController:self didFinishNormalizingCapturedImage:capturedImage];
                    });
                }
            }];
        }
        
        self.isCapturingImage = NO;
    });
}

#pragma mark - AV Orientation

- (void)_setPreviewVideoOrientation
{
    AVCaptureConnection *videoConnection = [_previewLayer connection];
    
    if ([videoConnection isVideoOrientationSupported]) {
        [videoConnection setVideoOrientation:[self _currentPreviewVideoOrientationForDevice]];
    }
}

- (AVCaptureVideoOrientation)_currentCaptureVideoOrientationForDevice
{
    UIDeviceOrientation actualOrientation = self.deviceOrientation.orientation;
    
    if (actualOrientation == UIDeviceOrientationFaceDown
        || actualOrientation == UIDeviceOrientationFaceUp
        || actualOrientation == UIDeviceOrientationUnknown) {
        return [self _currentPreviewVideoOrientationForDevice];
    }
    
    return [self.class _videoOrientationForDeviceOrientation:actualOrientation];
}

- (UIDeviceOrientation)_currentPreviewDeviceOrientation
{
    if (!self.interfaceRotatesWithOrientation) {
        return self.fixedInterfaceOrientation;
    }
    
    return [[UIDevice currentDevice] orientation];
}

- (AVCaptureVideoOrientation)_currentPreviewVideoOrientationForDevice
{
    UIDeviceOrientation deviceOrientation = [self _currentPreviewDeviceOrientation];

    return [self.class _videoOrientationForDeviceOrientation:deviceOrientation];
}

+ (AVCaptureVideoOrientation)_videoOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation
{
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
            
        case UIDeviceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
            
        case UIDeviceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeRight;
            
        case UIDeviceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeLeft;
            
        default:
            break;
    }
    
    return AVCaptureVideoOrientationPortrait;
}

#pragma mark - Camera Permissions

- (void)_checkDeviceAuthorizationWithCompletion:(void (^)(BOOL isAuthorized))completion
{
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (completion) {
            completion(granted);
        }
    }];
}

#pragma mark - FastttCameraDevice

- (AVCaptureDevice *)_currentCameraDevice
{
    return [_session.inputs.lastObject device];
}

- (AVCaptureConnection *)_currentCaptureConnection
{
    AVCaptureConnection *videoConnection = nil;
    
    for (AVCaptureConnection *connection in [_stillImageOutput connections]) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        
        if (videoConnection) {
            break;
        }
    }
    
    return videoConnection;
}

- (CGPoint)_focusPointOfInterestForTouchPoint:(CGPoint)touchPoint
{
    return [_previewLayer captureDevicePointOfInterestForPoint:touchPoint];
}

- (BOOL)_focusAtPointOfInterest:(CGPoint)pointOfInterest
{
    return [[self _currentCameraDevice] focusAtPointOfInterest:pointOfInterest];
}

- (void)_resetZoom
{
    [self.fastZoom resetZoom];
    
    self.fastZoom.maxScale = [[self _currentCameraDevice] videoMaxZoomFactor];
    
    self.maxZoomFactor = self.fastZoom.maxScale;
}

#pragma mark - FastttFocusDelegate

- (BOOL)handleTapFocusAtPoint:(CGPoint)touchPoint
{
    if ([AVCaptureDevice isPointFocusAvailableForCameraDevice:self.cameraDevice]) {
        
        CGPoint pointOfInterest = [self _focusPointOfInterestForTouchPoint:touchPoint];
        
        return ([self _focusAtPointOfInterest:pointOfInterest] && self.showsFocusView);
    }
    
    return NO;
}

#pragma mark - FastttZoomDelegate

- (BOOL)handlePinchZoomWithScale:(CGFloat)zoomScale
{
    return ([self zoomToScale:zoomScale] && self.showsZoomView);
}

@end
