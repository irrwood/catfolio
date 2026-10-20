import SwiftUI

enum PublicInvestorPortrait {
    static func assetName(for investorID: String) -> String? {
        guard ["pelosi", "hh", "berkshire", "scion", "ark", "musk"].contains(investorID) else { return nil }
        return "InvestorAvatar_\(investorID)"
    }
}

struct PublicInvestorAvatar: View {
    let investorID: String
    var size: CGFloat = 44

    var body: some View {
        if let asset = PublicInvestorPortrait.assetName(for: investorID) {
            Image(asset)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.96, height: size * 0.96)
                // All six 216 px assets have six transparent rows below the
                // portrait. Align the artwork, rather than its canvas, to the mask.
                .offset(y: size * 0.96 * 6 / 216)
                .frame(width: size, height: size, alignment: .bottom)
                .background(CatfolioPalette.InvestorPortrait.background(for: investorID),
                            in: AccountIdentityShape())
                .clipShape(AccountIdentityShape())
                .accessibilityHidden(true)
        }
    }
}
