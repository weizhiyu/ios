//
//  CheckAccessToServer.m
//  Owncloud iOs Client
//
//  Created by Javier Gonzalez on 8/21/12.
//

/*
 Copyright (C) 2014, ownCloud, Inc.
 This code is covered by the GNU Public License Version 3.
 For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 You should have received a copy of this license
 along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 */

#import "CheckAccessToServer.h"
#import <netinet/in.h>
#import <CFNetwork/CFNetwork.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "OCFrameworkConstants.h"
#import "UtilsUrls.h"

#import <openssl/x509.h>
#import <openssl/bio.h>
#import <openssl/err.h>
#include <openssl/pem.h>
#import "ManageAppSettingsDB.h"
#import "UtilsDtos.h"
#import "Customization.h"
#import "ManageUsersDB.h"

#ifdef CONTAINER_APP
#import "AppDelegate.h"
#endif

static NSString *const tmpFileName = @"tmp.der";

@implementation CheckAccessToServer


@synthesize delegate = _delegate;

//Singleton
+ (id)sharedManager {
    static CheckAccessToServer *sharedCheckAccessToServer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCheckAccessToServer = [[self alloc] init];
    });
    return sharedCheckAccessToServer;
}

static SecCertificateRef SecTrustGetLeafCertificate(SecTrustRef trust)
// Returns the leaf certificate from a SecTrust object (that is always the 
// certificate at index 0).
{
    SecCertificateRef   result;
    
    assert(trust != NULL);
    
    if (SecTrustGetCertificateCount(trust) > 0) {
        result = SecTrustGetCertificateAtIndex(trust, 0);
        assert(result != NULL);
    } else {
        result = NULL;
    }
    return result;
}


-(void) isConnectionToTheServerByUrl:(NSString *) url {
    [self isConnectionToTheServerByUrl:url withTimeout:k_timeout_webdav];
}

- (void)isConnectionToTheServerByUrl:(NSString *) url withTimeout:(NSInteger) timeout {
    
    //We save the url to later compare with urlServerRedirected in request
    self.urlUserToCheck = url;
    
    _urlStatusCheck = [NSString stringWithFormat:@"%@status.php", url];
    
    NSLog(@"URL Status: |%@|", _urlStatusCheck);
    
    
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_urlStatusCheck] cachePolicy:0 timeoutInterval:timeout];
    
    //Add the user agent
    [request addValue:[UtilsUrls getUserAgent] forHTTPHeaderField:@"User-Agent"];
    
    //Configure connectionSession
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:
                                  ^(NSData *data, NSURLResponse *response, NSError *error) {
                                      
                                      DLog(@"Error: %@", error);
                                      NSLog(@"Error: %ld - %@",(long)[error code] , [error localizedDescription]);
                                      
                                      if(error != nil){                                          
                                          //-1202 = self signed certificate
                                          if([error code] == -1202) {
                                              NSLog(@"Error -1202");
                                              
#ifdef CONTAINER_APP
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                  //Your main thread code goes in here
                                                  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"" message:NSLocalizedString(@"invalid_ssl_cert", nil) delegate: self cancelButtonTitle:NSLocalizedString(@"no", nil) otherButtonTitles:NSLocalizedString(@"yes", nil), nil];
                                                  [alert show];
                                                  [alert release];
                                              });
                                              
#else
                                              
                                              UIAlertController *alert =   [UIAlertController
                                                                            alertControllerWithTitle:@""
                                                                            message:NSLocalizedString(@"invalid_ssl_cert", nil)
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                                              UIAlertAction* no = [UIAlertAction
                                                                   actionWithTitle:NSLocalizedString(@"no", nil)
                                                                   style:UIAlertActionStyleDefault
                                                                   handler:^(UIAlertAction * action)
                                                                   {
                                                                       
                                                                   }];
                                              
                                              UIAlertAction* yes = [UIAlertAction
                                                                    actionWithTitle:NSLocalizedString(@"yes", nil)
                                                                    style:UIAlertActionStyleDefault
                                                                    handler:^(UIAlertAction * action)
                                                                    {
                                                                        [self acceptCertificate];
                                                                    }];
                                              [alert addAction:no];
                                              [alert addAction:yes];
                                              
                                              [self.viewControllerToShow presentViewController:alert animated:YES completion:nil];
                                              
#endif
                                              
                                          } else {
                                              if(self.delegate) {
                                                  [self.delegate connectionToTheServer:NO];
                                              }
                                          }
                                          
                                          
                                      }
                                      
                                      else{
                                          
                                          BOOL installed = NO;
                                          if (data!= nil) {
                                              
                                              NSError *e = nil;
                                              NSMutableDictionary *jsonArray = [NSJSONSerialization JSONObjectWithData: data options: NSJSONReadingMutableContainers error: &e];
                                              
                                              if (!jsonArray) {
                                                  NSLog(@"Error parsing JSON: %@", e);
                                              } else {
                                                  installed = [[jsonArray valueForKey:@"installed"] boolValue];
                                              }
                                          }
                                          
                                          if(self.delegate) {
                                              [self.delegate connectionToTheServer:installed];
                                          }
                                          
                                      }
                                      
                                  }];
    
    [task resume];
    
}


-(void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler{
    
    
    NSLog(@"didReceiveChallenge");
    
    BOOL trusted = NO;
    SecTrustRef trust;
    NSURLProtectionSpace *protectionSpace;
    
    protectionSpace = [challenge protectionSpace];
    trust = [protectionSpace serverTrust];
    
    [self createFolderToSaveCertificates];
    
    if(trust != nil) {
        [self saveCertificate:trust withName:tmpFileName];
        
        NSString *localCertificatesFolder = [UtilsUrls getLocalCertificatesPath];
        
        NSMutableArray *listCertificateLocation = [ManageAppSettingsDB getAllCertificatesLocation];
        
        for (int i = 0 ; i < [listCertificateLocation count] ; i++) {
            
            NSString *currentLocalCertLocation = [listCertificateLocation objectAtIndex:i];
            NSFileManager *fileManager = [ NSFileManager defaultManager];
            if([fileManager contentsEqualAtPath:[NSString stringWithFormat:@"%@%@",localCertificatesFolder,tmpFileName] andPath:[NSString stringWithFormat:@"%@",currentLocalCertLocation]]) {
                NSLog(@"Is the same certificate!!!");
                trusted = YES;
            }
        }
    } else {
        trusted = NO;
    }
 
    NSURLCredential *credential = nil;
    
    if (trusted) {
        credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential,credential);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, credential);
    }
}


- (void)saveCertificate:(SecTrustRef) trust withName:(NSString *) certName {
    SecCertificateRef currentServerCert = SecTrustGetLeafCertificate(trust);
    
    CFDataRef data = SecCertificateCopyData(currentServerCert);
    X509 *x509cert = NULL;
    if (data) {
        BIO *mem = BIO_new_mem_buf((void *)CFDataGetBytePtr(data), (int)CFDataGetLength(data));
        x509cert = d2i_X509_bio(mem, NULL);
        BIO_free(mem);
        CFRelease(data);
        
        if (!x509cert) {
            NSLog(@"OpenSSL couldn't parse X509 Certificate");
            
        } else {
            
            NSString *localCertificatesFolder = [UtilsUrls getLocalCertificatesPath];
            
            certName = [NSString stringWithFormat:@"%@%@",localCertificatesFolder,certName];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:certName]) {
                NSError *error;
                [[NSFileManager defaultManager] removeItemAtPath:certName error:&error];
            }
            
            FILE *file;
            file = fopen( [certName UTF8String], "w" );
            if (file) {
                PEM_write_X509(file, x509cert);
            }
            fclose(file);

        }
    
    } else {
        NSLog(@"Failed to retrieve DER data from Certificate Ref");
    }
    //Free
    X509_free(x509cert);
}

- (void)createFolderToSaveCertificates {
    NSString *documentsDirectory = [UtilsUrls getOwnCloudFilePath]; // Get documents folder
    NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:@"Certificates"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
        NSError *error = nil;
        
        [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:NO attributes:nil error:&error];
        
        NSLog(@"Error: %@", [error localizedDescription]);
    }
}

/*
 * Network status
 */
- (BOOL)isNetworkIsReachable {
    
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&zeroAddress);
    SCNetworkReachabilityFlags flags;
    BOOL gotFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
    CFRelease(defaultRouteReachability);
    if (!gotFlags) {
        return NO;
    }
    BOOL isReachable = flags & kSCNetworkReachabilityFlagsReachable;
    
    BOOL noConnectionRequired = !(flags & kSCNetworkReachabilityFlagsConnectionRequired);
    if ((flags & kSCNetworkReachabilityFlagsIsWWAN)) {
        noConnectionRequired = YES;
    }
    
    return (isReachable && noConnectionRequired) ? YES : NO;
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    
    if (buttonIndex == 1) {
        [self acceptCertificate];
    } else {
        NSLog(@"user pressed CANCEL");
        [self.delegate badCertificateNoAcceptedByUser];
    }
}

- (void) acceptCertificate {
    NSLog(@"user pressed YES");
    
    NSString *localCertificatesFolder = [UtilsUrls getLocalCertificatesPath];
    
    NSError * err = NULL;
    NSFileManager * fm = [[NSFileManager alloc] init];
    
    NSDate *date = [NSDate date];
    NSString *currentCertLocation = [NSString stringWithFormat:@"%@%f.der",localCertificatesFolder, [date timeIntervalSince1970]];
    
    NSLog(@"currentCertLocation: %@", currentCertLocation);
    
    BOOL result = [fm moveItemAtPath:[NSString stringWithFormat:@"%@%@",localCertificatesFolder, tmpFileName] toPath:currentCertLocation error:&err];
    if(!result) {
        NSLog(@"Error: %@", [err localizedDescription]);
    } else {
        [ManageAppSettingsDB insertCertificate:[NSString stringWithFormat:@"%f.der", [date timeIntervalSince1970]]];
        
    }
    [fm release];
    
    [self.delegate repeatTheCheckToTheServer];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)redirectResponse
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler{
    
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) redirectResponse;
    
    NSDictionary *dict = [httpResponse allHeaderFields];
    //Server path of redirected server
    NSString *responseURLString = [dict objectForKey:@"Location"];
    
    if (responseURLString) {
        
        //We obtain the urlServerRedirected to make the uploads in background 
        NSURL *url = [[NSURL alloc] initWithString:responseURLString];
        NSURL * urlByRemovingLastComponent = [url URLByDeletingLastPathComponent];

        UserDto *activeUser = [ManageUsersDB getActiveUser];
        if (activeUser) {
            if ([activeUser.url isEqualToString:self.urlUserToCheck]) {
                [ManageUsersDB updateUrlRedirected:[urlByRemovingLastComponent absoluteString] byUserDto:activeUser];
            }
        }
        
#ifdef CONTAINER_APP
        AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication]delegate];
        app.urlServerRedirected = [urlByRemovingLastComponent absoluteString];
        app.activeUser = [ManageUsersDB getActiveUser];
#endif

        NSLog(@"responseURLString: %@", responseURLString);
        NSLog(@"requestRedirect.HTTPMethod: %@", request.HTTPMethod);
        
        NSMutableURLRequest *requestRedirect = [request mutableCopy];
        
        [requestRedirect setURL: [NSURL URLWithString:responseURLString]];
        requestRedirect.HTTPMethod = @"GET";
        
        completionHandler(requestRedirect);
        
    } else {
        
        //We obtain the urlServerRedirected to make the uploads in background
#ifdef CONTAINER_APP
        AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication]delegate];
        app.urlServerRedirected = nil;
        app.activeUser = [ManageUsersDB getActiveUser];
#endif
        UserDto *activeUser = [ManageUsersDB getActiveUser];
        if (activeUser) {
            if ([activeUser.url isEqualToString:self.urlUserToCheck]) {
                [ManageUsersDB updateUrlRedirected:nil byUserDto:activeUser];
            }
        }
        
        completionHandler(request);
    }
}


@end
