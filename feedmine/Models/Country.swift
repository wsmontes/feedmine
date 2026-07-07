import Foundation

struct Country: Identifiable, Hashable {
    var id: String { region }
    let region: String          // "countries/brazil"
    let name: String            // "Brazil"
    let flag: String            // "🇧🇷"
    let feedCount: Int
    let categories: [String]

    var slug: String {
        region.replacingOccurrences(of: "countries/", with: "")
    }
}

enum CountryStore {
    /// Map OPML filename slug → (display name, emoji flag)
    private static let metadata: [String: (name: String, flag: String)] = [
        "algeria": ("Algeria", "🇩🇿"),
        "angola": ("Angola", "🇦🇴"),
        "argentina": ("Argentina", "🇦🇷"),
        "armenia": ("Armenia", "🇦🇲"),
        "australia": ("Australia", "🇦🇺"),
        "austria": ("Austria", "🇦🇹"),
        "azerbaijan": ("Azerbaijan", "🇦🇿"),
        "bangladesh": ("Bangladesh", "🇧🇩"),
        "belarus": ("Belarus", "🇧🇾"),
        "belgium": ("Belgium", "🇧🇪"),
        "bolivia": ("Bolivia", "🇧🇴"),
        "brazil": ("Brazil", "🇧🇷"),
        "bulgaria": ("Bulgaria", "🇧🇬"),
        "cambodia": ("Cambodia", "🇰🇭"),
        "canada": ("Canada", "🇨🇦"),
        "chile": ("Chile", "🇨🇱"),
        "china": ("China", "🇨🇳"),
        "colombia": ("Colombia", "🇨🇴"),
        "costa-rica": ("Costa Rica", "🇨🇷"),
        "croatia": ("Croatia", "🇭🇷"),
        "cuba": ("Cuba", "🇨🇺"),
        "cyprus": ("Cyprus", "🇨🇾"),
        "czech-republic": ("Czech Republic", "🇨🇿"),
        "denmark": ("Denmark", "🇩🇰"),
        "dominican-republic": ("Dominican Republic", "🇩🇴"),
        "ecuador": ("Ecuador", "🇪🇨"),
        "egypt": ("Egypt", "🇪🇬"),
        "el-salvador": ("El Salvador", "🇸🇻"),
        "estonia": ("Estonia", "🇪🇪"),
        "ethiopia": ("Ethiopia", "🇪🇹"),
        "finland": ("Finland", "🇫🇮"),
        "france": ("France", "🇫🇷"),
        "georgia": ("Georgia", "🇬🇪"),
        "germany": ("Germany", "🇩🇪"),
        "ghana": ("Ghana", "🇬🇭"),
        "greece": ("Greece", "🇬🇷"),
        "guatemala": ("Guatemala", "🇬🇹"),
        "haiti": ("Haiti", "🇭🇹"),
        "honduras": ("Honduras", "🇭🇳"),
        "hungary": ("Hungary", "🇭🇺"),
        "iceland": ("Iceland", "🇮🇸"),
        "india": ("India", "🇮🇳"),
        "indonesia": ("Indonesia", "🇮🇩"),
        "iran": ("Iran", "🇮🇷"),
        "iraq": ("Iraq", "🇮🇶"),
        "ireland": ("Ireland", "🇮🇪"),
        "israel": ("Israel", "🇮🇱"),
        "italy": ("Italy", "🇮🇹"),
        "ivory-coast": ("Ivory Coast", "🇨🇮"),
        "jamaica": ("Jamaica", "🇯🇲"),
        "japan": ("Japan", "🇯🇵"),
        "kazakhstan": ("Kazakhstan", "🇰🇿"),
        "kenya": ("Kenya", "🇰🇪"),
        "latvia": ("Latvia", "🇱🇻"),
        "lithuania": ("Lithuania", "🇱🇹"),
        "luxembourg": ("Luxembourg", "🇱🇺"),
        "malaysia": ("Malaysia", "🇲🇾"),
        "malta": ("Malta", "🇲🇹"),
        "mexico": ("Mexico", "🇲🇽"),
        "morocco": ("Morocco", "🇲🇦"),
        "myanmar": ("Myanmar", "🇲🇲"),
        "nepal": ("Nepal", "🇳🇵"),
        "netherlands": ("Netherlands", "🇳🇱"),
        "new-zealand": ("New Zealand", "🇳🇿"),
        "nicaragua": ("Nicaragua", "🇳🇮"),
        "nigeria": ("Nigeria", "🇳🇬"),
        "norway": ("Norway", "🇳🇴"),
        "pakistan": ("Pakistan", "🇵🇰"),
        "panama": ("Panama", "🇵🇦"),
        "paraguay": ("Paraguay", "🇵🇾"),
        "peru": ("Peru", "🇵🇪"),
        "philippines": ("Philippines", "🇵🇭"),
        "poland": ("Poland", "🇵🇱"),
        "portugal": ("Portugal", "🇵🇹"),
        "puerto-rico": ("Puerto Rico", "🇵🇷"),
        "qatar": ("Qatar", "🇶🇦"),
        "romania": ("Romania", "🇷🇴"),
        "russia": ("Russia", "🇷🇺"),
        "saudi-arabia": ("Saudi Arabia", "🇸🇦"),
        "serbia": ("Serbia", "🇷🇸"),
        "singapore": ("Singapore", "🇸🇬"),
        "slovakia": ("Slovakia", "🇸🇰"),
        "slovenia": ("Slovenia", "🇸🇮"),
        "south-africa": ("South Africa", "🇿🇦"),
        "south-korea": ("South Korea", "🇰🇷"),
        "spain": ("Spain", "🇪🇸"),
        "sri-lanka": ("Sri Lanka", "🇱🇰"),
        "sudan": ("Sudan", "🇸🇩"),
        "sweden": ("Sweden", "🇸🇪"),
        "switzerland": ("Switzerland", "🇨🇭"),
        "taiwan": ("Taiwan", "🇹🇼"),
        "thailand": ("Thailand", "🇹🇭"),
        "tunisia": ("Tunisia", "🇹🇳"),
        "turkey": ("Turkey", "🇹🇷"),
        "uae": ("UAE", "🇦🇪"),
        "ukraine": ("Ukraine", "🇺🇦"),
        "united-kingdom": ("United Kingdom", "🇬🇧"),
        "uruguay": ("Uruguay", "🇺🇾"),
        "venezuela": ("Venezuela", "🇻🇪"),
        "vietnam": ("Vietnam", "🇻🇳"),
    ]

    static func countryName(for slug: String) -> String {
        metadata[slug]?.name ?? slug.capitalized.replacingOccurrences(of: "-", with: " ")
    }

    static func countryFlag(for slug: String) -> String {
        metadata[slug]?.flag ?? "🌐"
    }
}
