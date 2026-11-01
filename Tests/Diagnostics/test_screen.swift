import Cocoa

// Test script to understand screen scaling
if let screen = NSScreen.main {
    print("=== Screen Information ===")
    print("Frame (logical points): \(screen.frame)")
    print("Visible frame: \(screen.visibleFrame)")
    print("Backing scale factor: \(screen.backingScaleFactor)")
    
    // Calculate actual pixel dimensions
    let logicalWidth = screen.frame.width
    let logicalHeight = screen.frame.height
    let scale = screen.backingScaleFactor
    
    let physicalWidth = logicalWidth * scale
    let physicalHeight = logicalHeight * scale
    
    print("\n=== Dimensions ===")
    print("Logical (points): \(logicalWidth) x \(logicalHeight)")
    print("Physical (pixels): \(physicalWidth) x \(physicalHeight)")
    print("Scale factor: \(scale)x")
    
    // Test notch calculation
    print("\n=== Notch Calculations ===")
    
    // Method 1: Percentage of logical width
    let notchWidthPercentage: CGFloat = 0.066
    let notchWidthLogical = logicalWidth * notchWidthPercentage
    print("Method 1 (6.6% of logical): \(notchWidthLogical) points")
    
    // Method 2: Fixed physical pixels converted to points
    let notchPhysicalPixels: CGFloat = 200
    let notchWidthFromPixels = notchPhysicalPixels / scale
    print("Method 2 (200px / scale): \(notchWidthFromPixels) points")
    
    // Method 3: Percentage of physical width
    let notchPhysicalPercentage = notchPhysicalPixels / physicalWidth
    let notchWidthFromPhysical = logicalWidth * notchPhysicalPercentage
    print("Method 3 (% of physical): \(notchWidthFromPhysical) points")
    
    print("\n=== Recommendation ===")
    print("The notch is always 200 physical pixels wide.")
    print("In logical points, this is: \(notchPhysicalPixels / scale) points")
}
