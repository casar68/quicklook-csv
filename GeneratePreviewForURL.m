//
//  GeneratePreviewForURL.m
//  QuickLookCSV
//
//  Created by Pascal Pfiffner on 03.07.2009.
//  This sourcecode is released under the Apache License, Version 2.0
//  http://www.apache.org/licenses/LICENSE-2.0.html
//  

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "CSVDocument.h"
#import "CSVRowObject.h"

#define MAX_ROWS 500

// DEPRECATED: QLPreviewRequestIsCancelled / QLPreviewRequestSetDataRepresentation (and the whole
// .qlgenerator CFPlugIn model wired up in main.c) were deprecated in macOS 12 in favor of
// QLPreviewingController hosted in a Preview Extension. Left in place for now; migrating to a
// Preview Extension is planned as a separate, upcoming project.

static char* htmlReadableFileEncoding(NSStringEncoding stringEncoding);
static char* humanReadableFileEncoding(NSStringEncoding stringEncoding);
static NSString* formatFilesize(float bytes);
static NSString* htmlEscape(NSString *string);


/**
 *  Generates a preview for the given file.
 *
 *  This function parses the CSV and generates an HTML string that can be presented by QuickLook.
 */
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
	@autoreleasepool {
		NSError *theErr = nil;
		NSURL *myURL = (__bridge NSURL *)url;
		
		// Load document data using NSStrings house methods
		// For huge files, maybe guess file encoding using `file --brief --mime` and use NSFileHandle? Not for now...
		NSStringEncoding stringEncoding;
		NSString *fileString = [NSString stringWithContentsOfURL:myURL usedEncoding:&stringEncoding error:&theErr];
		
		// We could not open the file, probably unknown encoding; try ISO-8859-1
		if (!fileString) {
			stringEncoding = NSISOLatin1StringEncoding;
			fileString = [NSString stringWithContentsOfURL:myURL encoding:stringEncoding error:&theErr];
			
			// Still no success, give up
			if (!fileString) {
				if (nil != theErr) {
					NSLog(@"Error opening the file: %@", theErr);
				}
				
				return noErr;
			}
		}
		
		
		// Parse the data if still interested in the preview
		if (false == QLPreviewRequestIsCancelled(preview)) {
			CSVDocument *csvDoc = [CSVDocument new];
			csvDoc.autoDetectSeparator = YES;
			
			NSUInteger numRowsParsed = [csvDoc numRowsFromCSVString:fileString maxRows:MAX_ROWS error:NULL];
			
			// Create HTML of the data if still interested in the preview
			if (false == QLPreviewRequestIsCancelled(preview)) {
				NSBundle *myBundle = [NSBundle bundleForClass:[CSVDocument class]];
				
				NSString *cssPath = [myBundle pathForResource:@"Style" ofType:@"css"];
				NSString *css = [[NSString alloc] initWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:NULL];
				
				NSString *path = [myURL path];
				NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
				
				// compose the html
				NSMutableString *html = [[NSMutableString alloc] initWithString:@"<!DOCTYPE html>\n"];
				[html appendString:@"<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\"><head>\n"];
				[html appendFormat:@"<meta http-equiv=\"Content-Type\" content=\"text/html; charset=%s\" />\n", htmlReadableFileEncoding(stringEncoding)];
				[html appendString:@"<style>\n"];
				if (nil != css) {
					[html appendString:css];
				}
				
				// info
				NSString *separatorDesc = [@"	" isEqualToString:csvDoc.separator] ? @"Tab" :
				([@"," isEqualToString:csvDoc.separator] ? @"Comma" :
				 ([@"|" isEqualToString:csvDoc.separator] ? @"Pipe" :
				  ([@";" isEqualToString:csvDoc.separator] ? @"Semicolon" : csvDoc.separator)));
				NSString *numRows = (numRowsParsed > MAX_ROWS) ?
				[NSString stringWithFormat:@"%i+", MAX_ROWS] :
				[NSString stringWithFormat:@"%lu", (unsigned long)numRowsParsed];
				[html appendFormat:@"</style></head><body><div class=\"file_info\"><b>%lu</b> %@, <b>%@</b> %@</div>",
				 (unsigned long)[csvDoc.columnKeys count],
				 (1 == [csvDoc.columnKeys count]) ? NSLocalizedString(@"column", nil) : NSLocalizedString(@"columns", nil),
				 numRows,
				 (1 == numRowsParsed) ? NSLocalizedString(@"row", nil) : NSLocalizedString(@"rows", nil)
				 ];
				[html appendFormat:@"<div class=\"file_info\"><b>%@</b>, %@-%@, %s</div><table>",
				 formatFilesize([fileAttributes[NSFileSize] floatValue]),
				 NSLocalizedString(separatorDesc, nil),
				 NSLocalizedString(@"Separated", nil),
				 humanReadableFileEncoding(stringEncoding)
				 ];
				
				// add the table rows
				// Cell content comes straight from the user-supplied file, so every value must be
				// HTML-escaped before being embedded - otherwise a crafted CSV/TSV cell can inject
				// markup or script into the QuickLook preview.
				BOOL altRow = NO;
				for (CSVRowObject *row in csvDoc.rows) {
					[html appendFormat:@"<tr%@><td>", altRow ? @" class=\"alt_row\"" : @""];
					
					NSMutableArray *escapedCells = [NSMutableArray arrayWithCapacity:[csvDoc.columnKeys count]];
					for (NSString *colKey in csvDoc.columnKeys) {
						[escapedCells addObject:htmlEscape([row columnForKey:colKey])];
					}
					[html appendString:[escapedCells componentsJoinedByString:@"</td><td>"]];
					[html appendString:@"</td></tr>\n"];
					
					altRow = !altRow;
				}
				
				[html appendString:@"</table>\n"];
				
				// not all rows were parsed, show hint
				if (numRowsParsed > MAX_ROWS) {
					NSString *rowsHint = [NSString stringWithFormat:NSLocalizedString(@"Only the first %i rows are being displayed", nil), MAX_ROWS];
					[html appendFormat:@"<div class=\"truncated_rows\">%@</div>", rowsHint];
				}
				[html appendString:@"</html>"];
				
				// feed the HTML
				CFDictionaryRef properties = (__bridge CFDictionaryRef)@{};
				QLPreviewRequestSetDataRepresentation(preview,
													  (__bridge CFDataRef)[html dataUsingEncoding:stringEncoding],
													  (__bridge CFStringRef)UTTypeHTML.identifier,
													  properties
													  );
			}
		}
	}
	
	return noErr;
}

void CancelPreviewGeneration(void* thisInterface, QLPreviewRequestRef preview)
{
}



#pragma mark - Output Utilities
/**
 *  To be used for the generated HTML.
 */
static char* htmlReadableFileEncoding(NSStringEncoding stringEncoding)
{
	if (NSUTF8StringEncoding == stringEncoding ||
	   NSUnicodeStringEncoding == stringEncoding) {
		return "utf-8";
	}
	if (NSASCIIStringEncoding == stringEncoding) {
		return "ascii";
	}
	if (NSISOLatin1StringEncoding == stringEncoding) {
		return "iso-8859-1";
	}
	if (NSMacOSRomanStringEncoding == stringEncoding) {
		return "x-mac-roman";
	}
	if (NSUTF16BigEndianStringEncoding == stringEncoding ||
	   NSUTF16LittleEndianStringEncoding == stringEncoding) {
		return "utf-16";
	}
	if (NSUTF32StringEncoding == stringEncoding ||
	   NSUTF32BigEndianStringEncoding == stringEncoding ||
	   NSUTF32LittleEndianStringEncoding == stringEncoding) {
		return "utf-32";
	}
	if (NSShiftJISStringEncoding == stringEncoding) {
		return "shift_jis";
	}
	
	return "utf-8";
}


static char* humanReadableFileEncoding(NSStringEncoding stringEncoding)
{
	if (NSUTF8StringEncoding == stringEncoding ||
	   NSUnicodeStringEncoding == stringEncoding) {
		return "UTF-8";
	}
	if (NSASCIIStringEncoding == stringEncoding) {
		return "ASCII-text";
	}
	if (NSISOLatin1StringEncoding == stringEncoding) {
		return "ISO-8859-1";
	}
	if (NSMacOSRomanStringEncoding == stringEncoding) {
		return "Mac-Roman";
	}
	if (NSUTF16BigEndianStringEncoding == stringEncoding ||
	   NSUTF16LittleEndianStringEncoding == stringEncoding) {
		return "UTF-16";
	}
	if (NSUTF32StringEncoding == stringEncoding ||
	   NSUTF32BigEndianStringEncoding == stringEncoding ||
	   NSUTF32LittleEndianStringEncoding == stringEncoding) {
		return "UTF-32";
	}
	if (NSShiftJISStringEncoding == stringEncoding) {
		return "Shift_JIS";
	}
	
	return "UTF-8";
}


/**
 *  Formats a byte count into a human-readable string, e.g. "4.20 MB".
 *
 *  Returns an autoreleased NSString rather than a fixed-size C buffer: the previous
 *  implementation used a `static char[9]` which was one byte too small for the longest
 *  possible output ("999.99 GB" + NUL needs 10 bytes) and, being `static`, was also unsafe
 *  to share across the concurrent preview requests this generator declares support for.
 */
static NSString* formatFilesize(float bytes) {
	if (bytes < 1) {
		return @"";
	}
	
	NSString *format[] = { @"%.0f", @"%.0f", @"%.2f", @"%.2f", @"%.2f", @"%.2f" };
	NSString *unit[] = { @"Byte", @"KB", @"MB", @"GB", @"TB", @"PB" };
	int i = 0;
	while (bytes > 1000) {
		bytes /= 1000;			// Since OS X 10.7 (or 10.6?) Apple uses "kilobyte" and no longer "Kilobyte" or "kibibyte"
		i++;
	}
	
	NSString *numberString = [NSString stringWithFormat:format[i], bytes];
	return [NSString stringWithFormat:@"%@ %@", numberString, unit[i]];
}


/**
 *  Escapes a string for safe embedding as HTML text content.
 */
static NSString* htmlEscape(NSString *string) {
	if (nil == string) {
		return @"";
	}
	
	NSMutableString *escaped = [string mutableCopy];
	[escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [escaped length])];
	
	return escaped;
}


