// Adapted from https://github.com/MasterQ32/zig-gamedev-lib/blob/master/src/netbpm.zig
// with permission from Felix Queißner
const Allocator = std.mem.Allocator;
const FormatInterface = @import("../format_interface.zig").FormatInterface;
const ImageFormat = image.ImageFormat;
const ImageStream = image.ImageStream;
const ImageInfo = image.ImageInfo;
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const color = @import("../color.zig");
const errors = @import("../errors.zig");
const ImageError = errors.ImageError;
const ImageReadError = errors.ImageReadError;
const ImageWriteError = errors.ImageWriteError;
const image = @import("../image.zig");
const std = @import("std");
const utils = @import("../utils.zig");

// this file implements the Portable Anymap specification provided by
// http://netpbm.sourceforge.net/doc/pbm.html // P1, P4 => bitmap
// http://netpbm.sourceforge.net/doc/pgm.html // P2, P5 => graymap
// http://netpbm.sourceforge.net/doc/ppm.html // P3, P6 => pixmap

/// one of the three types a netbpm graphic could be stored in.
pub const Format = enum {
    /// the image contains black-and-white pixels.
    bitmap,

    /// the image contains grayscale pixels.
    grayscale,

    /// the image contains RGB pixels.
    rgb,
};

pub const Header = struct {
    format: Format,
    binary: bool,
    width: usize,
    height: usize,
    max_value: usize,
};

fn parseHeader(reader: ImageStream.Reader) ImageReadError!Header {
    var header: Header = undefined;

    var magic: [2]u8 = undefined;
    _ = try reader.read(magic[0..]);

    if (std.mem.eql(u8, &magic, "P1")) {
        header.binary = false;
        header.format = .bitmap;
        header.max_value = 1;
    } else if (std.mem.eql(u8, &magic, "P2")) {
        header.binary = false;
        header.format = .grayscale;
    } else if (std.mem.eql(u8, &magic, "P3")) {
        header.binary = false;
        header.format = .rgb;
    } else if (std.mem.eql(u8, &magic, "P4")) {
        header.binary = true;
        header.format = .bitmap;
        header.max_value = 1;
    } else if (std.mem.eql(u8, &magic, "P5")) {
        header.binary = true;
        header.format = .grayscale;
    } else if (std.mem.eql(u8, &magic, "P6")) {
        header.binary = true;
        header.format = .rgb;
    } else {
        return ImageReadError.InvalidData;
    }

    var read_buffer: [16]u8 = undefined;

    header.width = try parseNumber(reader, read_buffer[0..]);
    header.height = try parseNumber(reader, read_buffer[0..]);
    if (header.format != .bitmap) {
        header.max_value = try parseNumber(reader, read_buffer[0..]);
    }

    return header;
}

fn isWhitespace(b: u8) bool {
    return switch (b) {
        // Whitespace (blanks, TABs, CRs, LFs).
        '\n', '\r', ' ', '\t' => true,
        else => false,
    };
}

fn readNextByte(reader: ImageStream.Reader) ImageReadError!u8 {
    while (true) {
        var b = try reader.readByte();
        switch (b) {
            // Before the whitespace character that delimits the raster, any characters
            // from a "#" through the next carriage return or newline character, is a
            // comment and is ignored. Note that this is rather unconventional, because
            // a comment can actually be in the middle of what you might consider a token.
            // Note also that this means if you have a comment right before the raster,
            // the newline at the end of the comment is not sufficient to delimit the raster.
            '#' => {
                // eat up comment
                while (true) {
                    var c = try reader.readByte();
                    switch (c) {
                        '\r', '\n' => break,
                        else => {},
                    }
                }
            },
            else => return b,
        }
    }
}

/// skips whitespace and comments, then reads a number from the stream.
/// this function reads one whitespace behind the number as a terminator.
fn parseNumber(reader: ImageStream.Reader, buffer: []u8) ImageReadError!usize {
    var input_length: usize = 0;
    while (true) {
        var b = try readNextByte(reader);
        if (isWhitespace(b)) {
            if (input_length > 0) {
                return std.fmt.parseInt(usize, buffer[0..input_length], 10) catch return ImageReadError.InvalidData;
            } else {
                continue;
            }
        } else {
            if (input_length >= buffer.len)
                return error.OutOfMemory;
            buffer[input_length] = b;
            input_length += 1;
        }
    }
}

fn loadBinaryBitmap(header: Header, data: []color.Grayscale1, reader: ImageStream.Reader) ImageReadError!void {
    var data_index: usize = 0;
    const data_end = header.width * header.height;

    var bit_reader = std.io.bitReader(.Big, reader);

    while (data_index < data_end) : (data_index += 1) {
        // set bit is black, cleared bit is white
        // bits are "left to right" (so msb to lsb)
        const read_bit = try bit_reader.readBitsNoEof(u1, 1);
        data[data_index] = color.Grayscale1{ .value = ~read_bit };
    }
}

fn loadAsciiBitmap(header: Header, data: []color.Grayscale1, reader: ImageStream.Reader) ImageReadError!void {
    var data_index: usize = 0;
    const data_end = header.width * header.height;

    while (data_index < data_end) {
        var b = try reader.readByte();
        if (isWhitespace(b)) {
            continue;
        }

        // 1 is black, 0 is white in PBM spec.
        // we use 1=white, 0=black in u1 format
        const pixel = if (b == '0') @as(u1, 1) else @as(u1, 0);
        data[data_index] = color.Grayscale1{ .value = pixel };

        data_index += 1;
    }
}

fn readLinearizedValue(reader: ImageStream.Reader, max_value: usize) ImageReadError!u8 {
    return if (max_value > 255)
        @truncate(u8, 255 * @as(usize, try reader.readIntBig(u16)) / max_value)
    else
        @truncate(u8, 255 * @as(usize, try reader.readByte()) / max_value);
}

fn loadBinaryGraymap(header: Header, pixels: *color.PixelStorage, reader: ImageStream.Reader) ImageReadError!void {
    var data_index: usize = 0;
    const data_end = header.width * header.height;
    if (header.max_value <= 255) {
        while (data_index < data_end) : (data_index += 1) {
            pixels.grayscale8[data_index] = color.Grayscale8{ .value = try readLinearizedValue(reader, header.max_value) };
        }
    } else {
        while (data_index < data_end) : (data_index += 1) {
            pixels.grayscale16[data_index] = color.Grayscale16{ .value = try reader.readIntBig(u16) };
        }
    }
}

fn loadAsciiGraymap(header: Header, pixels: *color.PixelStorage, reader: ImageStream.Reader) ImageReadError!void {
    var read_buffer: [16]u8 = undefined;

    var data_index: usize = 0;
    const data_end = header.width * header.height;

    if (header.max_value <= 255) {
        while (data_index < data_end) : (data_index += 1) {
            pixels.grayscale8[data_index] = color.Grayscale8{ .value = @truncate(u8, try parseNumber(reader, read_buffer[0..])) };
        }
    } else {
        while (data_index < data_end) : (data_index += 1) {
            pixels.grayscale16[data_index] = color.Grayscale16{ .value = @truncate(u16, try parseNumber(reader, read_buffer[0..])) };
        }
    }
}

fn loadBinaryRgbmap(header: Header, data: []color.Rgb24, reader: ImageStream.Reader) ImageReadError!void {
    var data_index: usize = 0;
    const data_end = header.width * header.height;

    while (data_index < data_end) : (data_index += 1) {
        data[data_index] = color.Rgb24{
            .r = try readLinearizedValue(reader, header.max_value),
            .g = try readLinearizedValue(reader, header.max_value),
            .b = try readLinearizedValue(reader, header.max_value),
        };
    }
}

fn loadAsciiRgbmap(header: Header, data: []color.Rgb24, reader: ImageStream.Reader) ImageReadError!void {
    var read_buffer: [16]u8 = undefined;

    var data_index: usize = 0;
    const data_end = header.width * header.height;

    while (data_index < data_end) : (data_index += 1) {
        var r = try parseNumber(reader, read_buffer[0..]);
        var g = try parseNumber(reader, read_buffer[0..]);
        var b = try parseNumber(reader, read_buffer[0..]);

        data[data_index] = color.Rgb24{
            .r = @truncate(u8, 255 * r / header.max_value),
            .g = @truncate(u8, 255 * g / header.max_value),
            .b = @truncate(u8, 255 * b / header.max_value),
        };
    }
}

fn Netpbm(comptime image_format: ImageFormat, comptime header_numbers: []const u8) type {
    return struct {
        header: Header = undefined,

        const Self = @This();

        pub const EncoderOptions = struct {
            binary: bool,
        };

        pub fn formatInterface() FormatInterface {
            return FormatInterface{
                .format = @ptrCast(FormatInterface.FormatFn, format),
                .formatDetect = @ptrCast(FormatInterface.FormatDetectFn, formatDetect),
                .readForImage = @ptrCast(FormatInterface.ReadForImageFn, readForImage),
                .writeForImage = @ptrCast(FormatInterface.WriteForImageFn, writeForImage),
            };
        }

        pub fn format() ImageFormat {
            return image_format;
        }

        pub fn formatDetect(stream: *ImageStream) ImageReadError!bool {
            var magic_number_buffer: [2]u8 = undefined;
            _ = try stream.read(magic_number_buffer[0..]);

            if (magic_number_buffer[0] != 'P') {
                return false;
            }

            var found = false;

            for (header_numbers) |number| {
                if (magic_number_buffer[1] == number) {
                    found = true;
                    break;
                }
            }

            return found;
        }

        pub fn readForImage(allocator: Allocator, stream: *ImageStream, pixels: *?color.PixelStorage) ImageReadError!ImageInfo {
            var netpbm_file = Self{};

            try netpbm_file.read(allocator, stream, pixels);

            var image_info = ImageInfo{};
            image_info.width = netpbm_file.header.width;
            image_info.height = netpbm_file.header.height;

            return image_info;
        }

        pub fn writeForImage(allocator: Allocator, write_stream: *ImageStream, pixels: color.PixelStorage, save_info: image.ImageSaveInfo) ImageWriteError!void {
            _ = allocator;
            var netpbm_file = Self{};
            netpbm_file.header.binary = switch (save_info.encoder_options) {
                .pbm => |options| options.binary,
                .pgm => |options| options.binary,
                .ppm => |options| options.binary,
                else => false,
            };

            netpbm_file.header.width = save_info.width;
            netpbm_file.header.height = save_info.height;
            netpbm_file.header.format = switch (pixels) {
                .grayscale1 => Format.bitmap,
                .grayscale8, .grayscale16 => Format.grayscale,
                .rgb24 => Format.rgb,
                else => return ImageError.Unsupported,
            };

            netpbm_file.header.max_value = switch (pixels) {
                .grayscale16 => std.math.maxInt(u16),
                .grayscale1 => 1,
                else => std.math.maxInt(u8),
            };

            try netpbm_file.write(write_stream, pixels);
        }

        pub fn pixelFormat(self: Self) ImageReadError!PixelFormat {
            return switch (self.header.format) {
                .bitmap => PixelFormat.grayscale1,
                .grayscale => switch (self.header.max_value) {
                    0...255 => PixelFormat.grayscale8,
                    else => PixelFormat.grayscale16,
                },
                .rgb => PixelFormat.rgb24,
            };
        }

        pub fn read(self: *Self, allocator: Allocator, stream: *ImageStream, pixels_opt: *?color.PixelStorage) ImageReadError!void {
            const reader = stream.reader();
            self.header = try parseHeader(reader);

            const pixel_format = try self.pixelFormat();

            pixels_opt.* = try color.PixelStorage.init(allocator, pixel_format, self.header.width * self.header.height);

            if (pixels_opt.*) |*pixels| {
                switch (self.header.format) {
                    .bitmap => {
                        if (self.header.binary) {
                            try loadBinaryBitmap(self.header, pixels.grayscale1, reader);
                        } else {
                            try loadAsciiBitmap(self.header, pixels.grayscale1, reader);
                        }
                    },
                    .grayscale => {
                        if (self.header.binary) {
                            try loadBinaryGraymap(self.header, pixels, reader);
                        } else {
                            try loadAsciiGraymap(self.header, pixels, reader);
                        }
                    },
                    .rgb => {
                        if (self.header.binary) {
                            try loadBinaryRgbmap(self.header, pixels.rgb24, reader);
                        } else {
                            try loadAsciiRgbmap(self.header, pixels.rgb24, reader);
                        }
                    },
                }
            }
        }

        pub fn write(self: *Self, write_stream: *ImageStream, pixels: color.PixelStorage) ImageWriteError!void {
            const image_type = if (self.header.binary) header_numbers[1] else header_numbers[0];
            const writer = write_stream.writer();
            try writer.print("P{c}\n", .{image_type});
            _ = try writer.write("# Created by zigimg\n");

            try writer.print("{} {}\n", .{ self.header.width, self.header.height });

            if (self.header.format != .bitmap) {
                try writer.print("{}\n", .{self.header.max_value});
            }

            if (self.header.binary) {
                switch (self.header.format) {
                    .bitmap => {
                        switch (pixels) {
                            .grayscale1 => {
                                var bit_writer = std.io.bitWriter(.Big, writer);

                                for (pixels.grayscale1) |entry| {
                                    try bit_writer.writeBits(~entry.value, 1);
                                }

                                try bit_writer.flushBits();
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                    .grayscale => {
                        switch (pixels) {
                            .grayscale16 => {
                                for (pixels.grayscale16) |entry| {
                                    // Big due to 16-bit PGM being semi standardized as big-endian
                                    try writer.writeIntBig(u16, entry.value);
                                }
                            },
                            .grayscale8 => {
                                for (pixels.grayscale8) |entry| {
                                    try writer.writeIntLittle(u8, entry.value);
                                }
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                    .rgb => {
                        switch (pixels) {
                            .rgb24 => {
                                for (pixels.rgb24) |entry| {
                                    try writer.writeByte(entry.r);
                                    try writer.writeByte(entry.g);
                                    try writer.writeByte(entry.b);
                                }
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                }
            } else {
                switch (self.header.format) {
                    .bitmap => {
                        switch (pixels) {
                            .grayscale1 => {
                                for (pixels.grayscale1) |entry| {
                                    try writer.print("{}", .{~entry.value});
                                }
                                _ = try writer.write("\n");
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                    .grayscale => {
                        switch (pixels) {
                            .grayscale16 => {
                                const pixels_len = pixels.len();
                                for (pixels.grayscale16) |entry, index| {
                                    try writer.print("{}", .{entry.value});

                                    if (index != (pixels_len - 1)) {
                                        _ = try writer.write(" ");
                                    }
                                }
                                _ = try writer.write("\n");
                            },
                            .grayscale8 => {
                                const pixels_len = pixels.len();
                                for (pixels.grayscale8) |entry, index| {
                                    try writer.print("{}", .{entry.value});

                                    if (index != (pixels_len - 1)) {
                                        _ = try writer.write(" ");
                                    }
                                }
                                _ = try writer.write("\n");
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                    .rgb => {
                        switch (pixels) {
                            .rgb24 => {
                                for (pixels.rgb24) |entry| {
                                    try writer.print("{} {} {}\n", .{ entry.r, entry.g, entry.b });
                                }
                            },
                            else => {
                                return ImageError.Unsupported;
                            },
                        }
                    },
                }
            }
        }
    };
}

pub const PBM = Netpbm(ImageFormat.pbm, &[_]u8{ '1', '4' });
pub const PGM = Netpbm(ImageFormat.pgm, &[_]u8{ '2', '5' });
pub const PPM = Netpbm(ImageFormat.ppm, &[_]u8{ '3', '6' });
