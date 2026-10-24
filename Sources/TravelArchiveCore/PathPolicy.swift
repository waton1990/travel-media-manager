import Foundation
import Darwin

// All operations below are relative to open directory descriptors. Resolving the
// selected roots once allows macOS aliases such as /var; paths below those roots
// must never contain symlinks.
enum PathPolicy {
    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0"), let path = realpath(url.path, nil) else {
            throw ArchiveError.invalid("无法访问所选文件夹：\(url.lastPathComponent)")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("无法打开根目录") }
        do {
            for component in url.pathComponents where component != "/" {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw systemError("无法安全访问文件夹：\(component)") }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func relativeComponents(file: URL, source: URL) throws -> [String] {
        guard file.isFileURL, !file.path.contains("\0") else { throw ArchiveError.invalid("素材路径无效。") }
        let root = source.standardizedFileURL.pathComponents
        let path = file.standardizedFileURL.pathComponents
        guard path.count > root.count, Array(path.prefix(root.count)) == root else {
            throw ArchiveError.invalid("素材不在所选来源文件夹内：\(file.lastPathComponent)")
        }
        let components = Array(path.dropFirst(root.count))
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveError.invalid("素材路径无效。")
        }
        return components
    }

    static func openSource(_ components: [String], in root: Int32) throws -> Int32 {
        guard let name = components.last else { throw ArchiveError.invalid("素材路径为空。") }
        var parent = dup(root)
        guard parent >= 0 else { throw systemError("无法读取素材目录") }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw systemError("素材目录发生变化或无法读取：\(component)") }
            close(parent)
            parent = next
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("素材发生变化或无法读取：\(name)") }
        do {
            _ = try snapshot(fd, name: name)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func snapshot(_ fd: Int32, name: String) throws -> FileSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("无法读取素材状态：\(name)") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError.invalid("不是普通素材文件：\(name)") }
        return FileSnapshot(stat: info)
    }

    static func directoryIdentity(_ fd: Int32) throws -> (device: Int64, inode: UInt64) {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw systemError("所选文件夹不可访问")
        }
        return (Int64(info.st_dev), UInt64(info.st_ino))
    }

    static func confirmDirectory(_ url: URL, fd: Int32) throws {
        let current = try openDirectory(try canonicalDirectory(url))
        defer { close(current) }
        let first = try directoryIdentity(fd)
        let second = try directoryIdentity(current)
        guard first == second else { throw ArchiveError.invalid("所选文件夹在操作期间发生变化，请重新选择并扫描。") }
    }

    static func isWithin(_ child: URL, _ parent: URL) -> Bool {
        let p = parent.pathComponents
        let c = child.pathComponents
        return c.count >= p.count && Array(c.prefix(p.count)) == p
    }

    static func systemError(_ message: String) -> ArchiveError {
        let code = errno
        return .invalid("\(message)（\(String(cString: strerror(code)))）")
    }
}
