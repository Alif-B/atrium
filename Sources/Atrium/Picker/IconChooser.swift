import AppKit
import UniformTypeIdentifiers

@MainActor
enum IconChooser {
    /// Lets the user pick any picture from the Mac (PNG, JPEG, HEIC, ICNS, ICO, …).
    static func chooseImage() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture to use as the icon"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    /// An image on the clipboard: a copied picture or screenshot, or an image file copied in Finder.
    static func imageFromPasteboard() -> NSImage? {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in files {
            if let image = NSImage(contentsOf: url), image.isValid { return image }
        }
        if NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard), image.isValid { return image }
        return nil
    }
}
