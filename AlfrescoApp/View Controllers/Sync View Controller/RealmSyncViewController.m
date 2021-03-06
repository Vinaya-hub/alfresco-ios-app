/*******************************************************************************
 * Copyright (C) 2005-2016 Alfresco Software Limited.
 *
 * This file is part of the Alfresco Mobile iOS App.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 ******************************************************************************/

#import "RealmSyncViewController.h"
#import "BaseFileFolderCollectionViewController+Internal.h"
#import "ConnectivityManager.h"
#import "SyncCollectionViewDataSource.h"
#import "RealmSyncManager.h"
#import "UniversalDevice.h"
#import "PreferenceManager.h"
#import "AccountManager.h"

#import "SyncObstaclesViewController.h"
#import "SyncNavigationViewController.h"
#import "FailedTransferDetailViewController.h"
#import "FileFolderCollectionViewCell.h"
#import "ALFSwipeToDeleteGestureRecognizer.h"


static CGFloat const kSyncOnSiteRequestsCompletionTimeout = 5.0; // seconds

static NSString * const kVersionSeriesValueKeyPath = @"properties.cmis:versionSeriesId.value";

@interface RealmSyncViewController () < RepositoryCollectionViewDataSourceDelegate >

@property (nonatomic) AlfrescoNode *parentNode;
@property (nonatomic, strong) AlfrescoDocumentFolderService *documentFolderService;
@property (nonatomic, assign) BOOL didSyncAfterSessionRefresh;

@property (nonatomic, strong) UIBarButtonItem *switchLayoutBarButtonItem;

@end

@implementation RealmSyncViewController

- (id)initWithParentNode:(AlfrescoNode *)node andSession:(id<AlfrescoSession>)session
{
    self = [super initWithSession:session];
    if (self)
    {
        self.session = session;
        self.parentNode = node;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if (self.parentNode != nil || ![[ConnectivityManager sharedManager] hasInternetConnection])
    {
        [self disablePullToRefresh];
    }
    
    [self adjustCollectionViewForProgressView:nil];
    
    [self changeCollectionViewStyle:self.style animated:YES];
    
    [self addNotificationListeners];
    
    if (!self.didSyncAfterSessionRefresh || self.parentNode != nil)
    {
        self.documentFolderService = [[AlfrescoDocumentFolderService alloc] initWithSession:self.session];
        [self loadSyncNodesForFolder:self.parentNode];
        [self reloadCollectionView];
        self.didSyncAfterSessionRefresh = YES;
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Private methods
- (void)reloadCollectionView
{
    [super reloadCollectionView];
    self.collectionView.contentOffset = CGPointMake(0., 0.);
}

- (void)addNotificationListeners
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(siteRequestsCompleted:)
                                                 name:kAlfrescoSiteRequestsCompletedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSyncObstacles:)
                                                 name:kSyncObstaclesNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didUpdatePreference:)
                                                 name:kSettingsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(adjustCollectionViewForProgressView:)
                                                 name:kSyncProgressViewVisiblityChangeNotification
                                               object:nil];
}

- (void)loadSyncNodesForFolder:(AlfrescoNode *)folder
{
    self.dataSource = [[SyncCollectionViewDataSource alloc] initWithParentNode:self.parentNode session:self.session delegate:self];
    
    self.listLayout.dataSourceInfoDelegate = self.dataSource;
    self.gridLayout.dataSourceInfoDelegate = self.dataSource;
    self.collectionView.dataSource = self.dataSource;
    
    self.title = self.dataSource.screenTitle;
    
    [self reloadCollectionView];
    [self hidePullToRefreshView];
}

- (void)performEditBarButtonItemAction:(UIBarButtonItem *)sender
{
    [self setupActionsAlertController];
    self.actionsAlertController.modalPresentationStyle = UIModalPresentationPopover;
    UIPopoverPresentationController *popPC = [self.actionsAlertController popoverPresentationController];
    popPC.barButtonItem = self.switchLayoutBarButtonItem;
    popPC.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popPC.delegate = self;
    
    [self presentViewController:self.actionsAlertController animated:YES completion:nil];
}

- (void)showPopoverForFailedSyncNodeAtIndexPath:(NSIndexPath *)indexPath
{
    RealmSyncManager *syncManager = [RealmSyncManager sharedManager];
    AlfrescoNode *node = [self.dataSource alfrescoNodeAtIndex:indexPath.row];
    NSString *errorDescription = [syncManager syncErrorDescriptionForNode:node];
    
    if (IS_IPAD)
    {
        __weak typeof(self) weakSelf = self;
        FailedTransferDetailViewController *syncFailedDetailController = [[FailedTransferDetailViewController alloc] initWithTitle:NSLocalizedString(@"sync.state.failed-to-sync", @"Upload failed popover title")
                                                                                                                           message:errorDescription retryCompletionBlock:^() {
                                                                                                                               [weakSelf retrySyncAndCloseRetryPopover];
                                                                                                                           }];
        
        if (self.retrySyncPopover)
        {
            [self.retrySyncPopover dismissPopoverAnimated:YES];
        }
        self.retrySyncPopover = [[UIPopoverController alloc] initWithContentViewController:syncFailedDetailController];
        [self.retrySyncPopover setPopoverContentSize:syncFailedDetailController.view.frame.size];
        
        FileFolderCollectionViewCell *cell = (FileFolderCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:indexPath];
        
        if (cell.accessoryView.window != nil)
        {
            [self.retrySyncPopover presentPopoverFromRect:cell.accessoryView.frame inView:cell permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        }
    }
    else
    {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"sync.state.failed-to-sync", @"Upload Failed")
                                    message:errorDescription
                                   delegate:self
                          cancelButtonTitle:NSLocalizedString(@"Close", @"Close")
                          otherButtonTitles:NSLocalizedString(@"Retry", @"Retry"), nil] show];
    }
}

- (void)retrySyncAndCloseRetryPopover
{
    [[RealmSyncManager sharedManager] retrySyncForDocument:(AlfrescoDocument *)self.retrySyncNode completionBlock:nil];
    [self.retrySyncPopover dismissPopoverAnimated:YES];
    self.retrySyncNode = nil;
    self.retrySyncPopover = nil;
}

- (void)cancelSync
{
    [[RealmSyncManager sharedManager] cancelAllSyncOperations];
}

#pragma mark - UICollectionViewDelegate methods
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    RealmSyncManager *syncManager = [RealmSyncManager sharedManager];
    AlfrescoNode *selectedNode = [self.dataSource alfrescoNodeAtIndex:indexPath.row];
    SyncNodeStatus *nodeStatus = [[RealmSyncManager sharedManager] syncStatusForNodeWithId:selectedNode.identifier];
    
    if (selectedNode.isFolder)
    {
        RealmSyncViewController *controller = [[RealmSyncViewController alloc] initWithParentNode:selectedNode andSession:self.session];
        controller.style = self.style;
        [self.navigationController pushViewController:controller animated:YES];
    }
    else
    {
        if (nodeStatus.status == SyncStatusLoading)
        {
            [self.collectionView deselectItemAtIndexPath:indexPath animated:YES];
            return;
        }
        
        NSString *filePath = [syncManager contentPathForNode:(AlfrescoDocument *)selectedNode];
        AlfrescoPermissions *syncNodePermissions = [syncManager permissionsForSyncNode:selectedNode];
        if (filePath)
        {
            if ([[ConnectivityManager sharedManager] hasInternetConnection])
            {
                [UniversalDevice pushToDisplayDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                               permissions:syncNodePermissions
                                                                               contentFile:filePath
                                                                          documentLocation:InAppDocumentLocationSync
                                                                                   session:self.session
                                                                      navigationController:self.navigationController
                                                                                  animated:YES];
            }
            else
            {
                [UniversalDevice pushToDisplayDownloadDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                                       permissions:nil
                                                                                       contentFile:filePath
                                                                                  documentLocation:InAppDocumentLocationSync
                                                                                           session:self.session
                                                                              navigationController:self.navigationController
                                                                                          animated:YES];
            }
        }
        else if ([[ConnectivityManager sharedManager] hasInternetConnection])
        {
            [self showHUD];
            __weak typeof(self) weakSelf = self;
            [self.documentFolderService retrievePermissionsOfNode:selectedNode completionBlock:^(AlfrescoPermissions *permissions, NSError *error) {
                
                [weakSelf hideHUD];
                if (!error)
                {
                    [UniversalDevice pushToDisplayDocumentPreviewControllerForAlfrescoDocument:(AlfrescoDocument *)selectedNode
                                                                                   permissions:permissions
                                                                                   contentFile:filePath
                                                                              documentLocation:InAppDocumentLocationFilesAndFolders
                                                                                       session:weakSelf.session
                                                                          navigationController:weakSelf.navigationController
                                                                                      animated:YES];
                }
                else
                {
                    // display an error
                    NSString *permissionRetrievalErrorMessage = [NSString stringWithFormat:NSLocalizedString(@"error.filefolder.permission.notfound", "Permission Retrieval Error"), selectedNode.name];
                    displayErrorMessage(permissionRetrievalErrorMessage);
                    [Notifier notifyWithAlfrescoError:error];
                }
            }];
        }
    }
}

#pragma mark - Notifications methods
- (void)sessionReceived:(NSNotification *)notification
{
    id<AlfrescoSession> session = notification.object;
    self.session = session;
    self.documentFolderService = [[AlfrescoDocumentFolderService alloc] initWithSession:self.session];
    self.didSyncAfterSessionRefresh = NO;
    self.dataSource.session = session;
    self.title = self.dataSource.screenTitle;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
    // Hold off making sync network requests until either the Sites requests have completed, or a timeout period has passed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSyncOnSiteRequestsCompletionTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        if (!self.didSyncAfterSessionRefresh)
        {
            [self loadSyncNodesForFolder:self.parentNode];
            self.didSyncAfterSessionRefresh = YES;
        }
    });
}

- (void)siteRequestsCompleted:(NSNotification *)notification
{
    [self loadSyncNodesForFolder:self.parentNode];
    self.didSyncAfterSessionRefresh = YES;
}

- (void)didUpdatePreference:(NSNotification *)notification
{
    NSString *preferenceKeyChanged = notification.object;
    BOOL isCurrentlyOnCellular = [[ConnectivityManager sharedManager] isOnCellular];
    
    if ([preferenceKeyChanged isEqualToString:kSettingsSyncOnCellularIdentifier] && isCurrentlyOnCellular)
    {
        BOOL shouldSyncOnCellular = [notification.userInfo[kSettingChangedToKey] boolValue];
        
        // if changed to no and is syncing, then cancel sync
        if ([[RealmSyncManager sharedManager] isCurrentlySyncing] && !shouldSyncOnCellular)
        {
            [self cancelSync];
        }
        else if (shouldSyncOnCellular)
        {
            [self loadSyncNodesForFolder:self.parentNode];
        }
    }
}

#warning Change progressDelegate from SyncManagerProgressDelegate to RealmSyncManagerProgressDelegate and the new Realm backed system - part of IOS-564
- (void)adjustCollectionViewForProgressView:(NSNotification *)notification
{
    id navigationController = self.navigationController;
    
    if((notification) && (notification.object) && (navigationController != notification.object) && ([navigationController conformsToProtocol: @protocol(SyncManagerProgressDelegate)]))
    {
        /* The sender is not the navigation controller of this view controller, but the navigation controller of another instance of SyncViewController (namely the favorites view controller
         which was created when the account was first added). Will update the progress delegate on SyncManager to be able to show the progress view. The cause of this problem is a timing issue
         between begining the syncing process, menu reloading and delegate calls and notifications going around from component to component.
         */
        [SyncManager sharedManager].progressDelegate = navigationController;
    }
    
    if ([navigationController isKindOfClass:[SyncNavigationViewController class]])
    {
        SyncNavigationViewController *syncNavigationController = (SyncNavigationViewController *)navigationController;
        
        UIEdgeInsets edgeInset = UIEdgeInsetsMake(0.0, 0.0, 0.0, 0.0);
        if ([syncNavigationController isProgressViewVisible])
        {
            edgeInset = UIEdgeInsetsMake(0.0, 0.0, [syncNavigationController progressViewHeight], 0.0);
        }
        self.collectionView.contentInset = edgeInset;
    }
}

- (void)handleSyncObstacles:(NSNotification *)notification
{
    NSMutableDictionary *syncObstacles = [[notification.userInfo objectForKey:kSyncObstaclesKey] mutableCopy];
    
    if (syncObstacles)
    {
        SyncObstaclesViewController *syncObstaclesController = [[SyncObstaclesViewController alloc] initWithErrors:syncObstacles];
        syncObstaclesController.modalPresentationStyle = UIModalPresentationFormSheet;
        
        UINavigationController *syncObstaclesNavigationController = [[UINavigationController alloc] initWithRootViewController:syncObstaclesController];
        [UniversalDevice displayModalViewController:syncObstaclesNavigationController onController:self withCompletionBlock:nil];
    }
}

- (void)connectivityChanged:(NSNotification *)notification
{
    [super connectivityChanged:notification];
    [self loadSyncNodesForFolder:self.parentNode];
}

@end
