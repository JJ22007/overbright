import Foundation

struct ColorProfileIdentity: Equatable {
    let iccProfileData: Data?
    let fallbackName: String?

    func matches(_ other: ColorProfileIdentity) -> Bool {
        if let iccProfileData, let otherData = other.iccProfileData {
            return iccProfileData == otherData
        }
        return fallbackName == other.fallbackName
    }
}
