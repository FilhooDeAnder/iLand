import Cocoa

// Test notch dimensions for MacBook Air
if let screen = NSScreen.main {
    let screenFrame = screen.frame
    let scale = screen.backingScaleFactor
    
    print("=== MacBook Air M2 Screen ===")
    print("Logical size: \(screenFrame.width) x \(screenFrame.height)")
    print("Scale factor: \(scale)x")
    print("Physical pixels: \(screenFrame.width * scale) x \(screenFrame.height * scale)")
    
    // MacBook Air notch is smaller than Pro
    // Air: approximately 150px wide x 37px tall (physical pixels)
    // Pro: approximately 200px wide x 64px tall (physical pixels)
    
    let airNotchPhysicalWidth: CGFloat = 150
    let airNotchPhysicalHeight: CGFloat = 37
    
    let notchWidth = airNotchPhysicalWidth / scale
    let notchHeight = airNotchPhysicalHeight / scale
    
    print("\n=== MacBook Air Notch (estimated) ===")
    print("Physical: \(airNotchPhysicalWidth) x \(airNotchPhysicalHeight) pixels")
    print("Logical: \(notchWidth) x \(notchHeight) points")
    
    let x = screenFrame.midX - (notchWidth / 2)
    let y = screenFrame.maxY - notchHeight
    
    print("\n=== Notch Position ===")
    print("Rect: (\(x), \(y), \(notchWidth), \(notchHeight))")
}
