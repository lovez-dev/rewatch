const std = @import("std");
const w = std.os.windows;
const BOOL = w.BOOL;
const HANDLE = w.HANDLE;
const DWORD = w.DWORD;

extern "kernel32" fn CreateJobObjectW(?*w.SECURITY_ATTRIBUTES, ?w.LPCWSTR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(HANDLE, c_int, *const anyopaque, DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn QueryInformationJobObject(HANDLE, c_int, *anyopaque, DWORD, ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(HANDLE, HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(HANDLE, u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(HANDLE, u32) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GenerateConsoleCtrlEvent(DWORD, DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (DWORD) callconv(.winapi) BOOL, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn DuplicateHandle(HANDLE, HANDLE, HANDLE, *HANDLE, DWORD, BOOL, DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, DWORD, DWORD, *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, DWORD, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;

const StartupInfoEx = extern struct {
    startup: w.STARTUPINFOW,
    attributes: ?*anyopaque,
};
const proc_thread_attribute_handle_list: usize = 0x20002;

const BasicLimits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: DWORD = 0x2000, // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_process_limit: DWORD = 0,
    affinity: usize = 0,
    priority: DWORD = 0,
    scheduling: DWORD = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    user_time: i64,
    kernel_time: i64,
    period_user_time: i64,
    period_kernel_time: i64,
    page_faults: DWORD,
    total_processes: DWORD,
    active_processes: DWORD,
    terminated_processes: DWORD,
};

var interrupted = std.atomic.Value(bool).init(false);

fn consoleHandler(event: DWORD) callconv(.winapi) BOOL {
    switch (event) {
        0, 1 => {
            interrupted.store(true, .release);
            return .TRUE;
        },
        else => return .FALSE,
    }
}

pub fn installInterrupt() !void {
    interrupted.store(false, .release);
    if (SetConsoleCtrlHandler(consoleHandler, .TRUE) == .FALSE) return lastError();
}

pub fn uninstallInterrupt() void {
    _ = SetConsoleCtrlHandler(consoleHandler, .FALSE);
}

pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

pub const Process = struct {
    handle: HANDLE,
    job: HANDLE,
    pid: DWORD,
    reported: bool = false,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Process {
        _ = io;
        const command = try commandLine(allocator, argv);
        defer allocator.free(command);
        const job = CreateJobObjectW(null, null) orelse return lastError();
        errdefer w.CloseHandle(job);
        const limits: ExtendedLimits = .{};
        if (SetInformationJobObject(job, 9, &limits, @sizeOf(ExtendedLimits)) == .FALSE) return lastError();

        const params = w.peb().ProcessParameters;
        var handles: [3]HANDLE = undefined;
        var count: usize = 0;
        defer for (handles[0..count]) |handle| w.CloseHandle(handle);
        for ([_]HANDLE{ params.hStdInput, params.hStdOutput, params.hStdError }) |handle| {
            if (DuplicateHandle(w.GetCurrentProcess(), handle, w.GetCurrentProcess(), &handles[count], 0, .TRUE, 2) == .FALSE) return lastError();
            count += 1;
        }
        var attribute_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
        if (attribute_size == 0) return lastError();
        const attribute_storage = try allocator.alignedAlloc(u8, .of(usize), attribute_size);
        defer allocator.free(attribute_storage);
        const attributes: *anyopaque = @ptrCast(attribute_storage.ptr);
        if (InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) == .FALSE) return lastError();
        defer DeleteProcThreadAttributeList(attributes);
        // The list and duplicated streams stay valid through CreateProcessW.
        // Restrict inheritance while proxy tasks may hold unrelated socket handles.
        if (UpdateProcThreadAttribute(attributes, 0, proc_thread_attribute_handle_list, &handles, @sizeOf(@TypeOf(handles)), null, null) == .FALSE) return lastError();
        var startup = std.mem.zeroes(StartupInfoEx);
        startup.startup.cb = @sizeOf(StartupInfoEx);
        startup.startup.dwFlags = w.STARTF_USESTDHANDLES;
        startup.startup.hStdInput = handles[0];
        startup.startup.hStdOutput = handles[1];
        startup.startup.hStdError = handles[2];
        startup.attributes = attributes;
        var info: w.PROCESS.INFORMATION = undefined;
        if (w.kernel32.CreateProcessW(null, command.ptr, null, null, .TRUE, .{
            .create_suspended = true,
            .create_new_process_group = true,
            .extended_startupinfo_present = true,
        }, null, null, &startup.startup, &info) == .FALSE) return lastError();
        defer w.CloseHandle(info.hThread);
        errdefer {
            _ = TerminateProcess(info.hProcess, 1);
            _ = WaitForSingleObject(info.hProcess, 0xffffffff);
            w.CloseHandle(info.hProcess);
        }
        // Assignment happens before the child can create descendants.
        if (AssignProcessToJobObject(job, info.hProcess) == .FALSE) return error.JobAssignmentFailed;
        if (ResumeThread(info.hThread) == 0xffffffff) return lastError();
        return .{ .handle = info.hProcess, .job = job, .pid = info.dwProcessId };
    }

    pub fn poll(self: *Process, io: std.Io) !?u32 {
        _ = io;
        if (self.reported) return null;
        switch (WaitForSingleObject(self.handle, 0)) {
            0x102 => return null,
            0 => {},
            else => return lastError(),
        }
        var code: DWORD = undefined;
        if (GetExitCodeProcess(self.handle, &code) == .FALSE) return lastError();
        self.reported = true;
        return code;
    }

    pub fn requestStop(self: *Process) void {
        // Console applications may handle CTRL_BREAK. Detached/GUI programs need forceStop.
        _ = GenerateConsoleCtrlEvent(1, self.pid);
    }

    pub fn forceStop(self: *Process) !void {
        if (TerminateJobObject(self.job, 1) == .FALSE) return lastError();
    }

    pub fn empty(self: *Process, io: std.Io) !bool {
        _ = io;
        var accounting: Accounting = undefined;
        if (QueryInformationJobObject(self.job, 1, &accounting, @sizeOf(Accounting), null) == .FALSE) return lastError();
        return accounting.active_processes == 0;
    }

    /// Closing the job is also the last-resort cleanup on an error path.
    pub fn deinit(self: *Process, io: std.Io) void {
        _ = io;
        w.CloseHandle(self.job);
        _ = WaitForSingleObject(self.handle, 0xffffffff);
        w.CloseHandle(self.handle);
    }
};

fn lastError() error{ FileNotFound, AccessDenied, InvalidExecutable, WindowsCallFailed } {
    return switch (w.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .BAD_EXE_FORMAT => error.InvalidExecutable,
        else => error.WindowsCallFailed,
    };
}

/// The caller frees the returned UTF-16 command line after CreateProcessW.
fn commandLine(a: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    for (argv, 0..) |arg, index| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
        if (index == 0 and std.mem.indexOfScalar(u8, arg, '"') != null) return error.InvalidCommand;
        if (index > 0) try bytes.append(a, ' ');
        try bytes.append(a, '"');
        if (index == 0) {
            try bytes.appendSlice(a, arg);
        } else {
            var slashes: usize = 0;
            for (arg) |c| {
                if (c == '\\') {
                    slashes += 1;
                    continue;
                }
                try bytes.appendNTimes(a, '\\', if (c == '"') slashes * 2 + 1 else slashes);
                slashes = 0;
                try bytes.append(a, c);
            }
            try bytes.appendNTimes(a, '\\', slashes * 2);
        }
        try bytes.append(a, '"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(a, bytes.items);
}

test "Windows quoting preserves empty arguments quotes and trailing slashes" {
    const a = std.testing.allocator;
    const line = try commandLine(a, &.{ "C:\\Program Files\\app.exe", "", "a\"b", "trailing\\", "你好" });
    defer a.free(line);
    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(a, line);
    defer a.free(utf8);
    try std.testing.expectEqualStrings("\"C:\\Program Files\\app.exe\" \"\" \"a\\\"b\" \"trailing\\\\\" \"你好\"", utf8);
}
