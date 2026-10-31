import Foundation
import IOKit

class SMCReader {
    private static let SMC_CMD_READ_KEYINFO: UInt8 = 9
    private static let SMC_CMD_READ_BYTES: UInt8 = 5
    
    private var conn: io_connect_t = 0
    
    init?() {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        )
        
        guard result == kIOReturnSuccess else { return nil }
        
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        
        guard device != 0 else { return nil }
        
        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        
        guard openResult == kIOReturnSuccess else { return nil }
    }
    
    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }
    
    func readTemperature(key: String) -> Double? {
        guard let bytes = readKey(key), bytes.count >= 2 else { return nil }
        
        let intValue = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(intValue) / 256.0
    }
    
    private func readKey(_ key: String) -> [UInt8]? {
        var inputStruct = SMCKeyData_t()
        var outputStruct = SMCKeyData_t()
        
        guard key.count == 4 else { return nil }
        
        let keyBytes = key.utf8.map { UInt8($0) }
        inputStruct.key = UInt32(keyBytes[0]) << 24 |
                         UInt32(keyBytes[1]) << 16 |
                         UInt32(keyBytes[2]) << 8 |
                         UInt32(keyBytes[3])
        
        inputStruct.data8 = SMCReader.SMC_CMD_READ_KEYINFO
        
        var outputStructSize = MemoryLayout<SMCKeyData_t>.size
        
        let result = IOConnectCallStructMethod(
            conn,
            2,
            &inputStruct,
            MemoryLayout<SMCKeyData_t>.size,
            &outputStruct,
            &outputStructSize
        )
        
        guard result == kIOReturnSuccess else { return nil }
        
        inputStruct.keyInfo = outputStruct.keyInfo
        inputStruct.data8 = SMCReader.SMC_CMD_READ_BYTES
        
        let readResult = IOConnectCallStructMethod(
            conn,
            2,
            &inputStruct,
            MemoryLayout<SMCKeyData_t>.size,
            &outputStruct,
            &outputStructSize
        )
        
        guard readResult == kIOReturnSuccess else { return nil }
        
        return withUnsafeBytes(of: &outputStruct.bytes) { ptr in
            Array(ptr.bindMemory(to: UInt8.self).prefix(Int(outputStruct.keyInfo.dataSize)))
        }
    }
}

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes_t()
}

struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCBytes_t {
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
