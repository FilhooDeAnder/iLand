import Cocoa

// Check if Mac has a notch
if let screen = NSScreen.main {
    let screenFrame = screen.frame
    let visibleFrame = screen.visibleFrame
    
    print("=== Screen Info ===")
    print("Full frame: \(screenFrame)")
    print("Visible frame: \(visibleFrame)")
    print("Frame height: \(screenFrame.height)")
    print("Visible height: \(visibleFrame.height)")
    print("Top difference: \(screenFrame.maxY - visibleFrame.maxY)")
    
    // If there's a notch, the visible frame's top will be lower than the full frame
    // because the menu bar area includes the notch
    let hasNotch = screenFrame.maxY - visibleFrame.maxY > 30
    
    print("\n=== Notch Detection ===")
    print("Has notch: \(hasNotch)")
    
    if hasNotch {
        print("✅ MacBook Pro with notch detected")
    } else {
        print("❌ MacBook Air or older model (no notch)")
    }
}
