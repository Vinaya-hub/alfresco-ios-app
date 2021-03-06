/*******************************************************************************
 * Copyright (C) 2005-2014 Alfresco Software Limited.
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
 
#import "NodePickerFavoritesViewController.h"
#import "SyncManager.h"
#import "FavouriteManager.h"
#import "NodePickerFileFolderListViewController.h"
#import "AlfrescoNodeCell.h"
#import "ThumbnailManager.h"

static CGFloat const kCellHeight = 64.0f;

@interface NodePickerFavoritesViewController ()

@property (nonatomic) AlfrescoFolder *parentNode;
@property (nonatomic, strong) AlfrescoDocumentFolderService *documentFolderService;
@property (nonatomic, weak) NodePicker *nodePicker;

@end

@implementation NodePickerFavoritesViewController

- (instancetype)initWithParentNode:(AlfrescoFolder *)node
                           session:(id<AlfrescoSession>)session
              nodePickerController:(NodePicker *)nodePicker
{
    self = [super initWithNibName:NSStringFromClass([self class]) andSession:session];
    if (self)
    {
        _parentNode = node;
        _nodePicker = nodePicker;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.documentFolderService = [[AlfrescoDocumentFolderService alloc] initWithSession:self.session];
    [self loadSyncNodesForFolder:self.parentNode];
    self.allowsPullToRefresh = NO;
    
    self.title = [self listTitle];
    
    UINib *nib = [UINib nibWithNibName:@"AlfrescoNodeCell" bundle:nil];
    [self.tableView registerNib:nib forCellReuseIdentifier:[AlfrescoNodeCell cellIdentifier]];
    
    [self updateSelectFolderButton];
    
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                  target:self
                                                                                  action:@selector(cancelButtonPressed:)];
    self.navigationItem.rightBarButtonItem = cancelButton;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.nodePicker updateMultiSelectToolBarActions];
    
    if (self.nodePicker.type == NodePickerTypeFolders)
    {
        [self.nodePicker deselectAllNodes];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
}

- (void)cancelButtonPressed:(id)sender
{
    [self.nodePicker cancel];
}

- (void)updateSelectFolderButton
{
    if (self.nodePicker.type == NodePickerTypeFolders)
    {
        if (self.parentNode)
        {
            [self.nodePicker replaceSelectedNodesWithNodes:@[self.parentNode]];
        }
    }
}

#pragma mark - Private Methods

- (void)loadSyncNodesForFolder:(AlfrescoNode *)folder
{
    BOOL isSyncOn = [[SyncManager sharedManager] isSyncPreferenceOn];
    
    if (isSyncOn)
    {
        NSMutableArray *syncNodes = [[SyncManager sharedManager] topLevelSyncNodesOrNodesInFolder:self.parentNode];
        
        if (self.nodePicker.type == NodePickerTypeFolders)
        {
            self.tableViewData = [self foldersInNodes:syncNodes];
        }
        else
        {
            self.tableViewData = syncNodes;
        }

        BOOL isMultiSelectMode = (self.nodePicker.mode == NodePickerModeMultiSelect) && (self.tableViewData.count > 0);
        self.tableView.editing = isMultiSelectMode;
        self.tableView.allowsMultipleSelectionDuringEditing = isMultiSelectMode;
        [self.tableView reloadData];
    }
    else
    {
        [self showHUD];
        [self.documentFolderService retrieveFavoriteNodesWithCompletionBlock:^(NSArray *array, NSError *error) {
            [self hideHUD];
            if (self.nodePicker.type == NodePickerTypeFolders)
            {
                self.tableViewData = [self foldersInNodes:array];
            }
            else
            {
                self.tableViewData = [array mutableCopy];
            }
            
            BOOL isMultiSelectMode = (self.nodePicker.mode == NodePickerModeMultiSelect) && (self.tableViewData.count > 0);
            self.tableView.editing = isMultiSelectMode;
            self.tableView.allowsMultipleSelectionDuringEditing = isMultiSelectMode;
            [self.tableView reloadData];
        }];
    }
}

- (NSMutableArray *)foldersInNodes:(NSArray *)nodes
{
    NSPredicate *folderPredicate = [NSPredicate predicateWithFormat:@"SELF.isFolder == YES"];
    NSMutableArray *folders = [[nodes filteredArrayUsingPredicate:folderPredicate] mutableCopy];
    return folders;
}

- (NSString *)listTitle
{
    NSString *title = @"";
    BOOL isSyncOn = [[SyncManager sharedManager] isSyncPreferenceOn];
    
    if (self.parentNode)
    {
        title = self.parentNode.name;
    }
    else
    {
        title = isSyncOn ? NSLocalizedString(@"sync.title", @"Sync Title") : NSLocalizedString(@"favourites.title", @"Favorites Title");
    }
    
    self.tableView.emptyMessage = isSyncOn ? NSLocalizedString(@"sync.empty", @"No Synced Content") : NSLocalizedString(@"favourites.empty", @"No Favorites");
    return title;
}

#pragma mark - Table view data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.tableViewData.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return kCellHeight;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self.nodePicker isSelectionEnabledForNode:self.tableViewData[indexPath.row]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    AlfrescoNodeCell *nodeCell = [tableView dequeueReusableCellWithIdentifier:[AlfrescoNodeCell cellIdentifier]];
    
    SyncManager *syncManager = [SyncManager sharedManager];
    FavouriteManager *favoriteManager = [FavouriteManager sharedManager];
    
    AlfrescoNode *node = self.tableViewData[indexPath.row];
    SyncNodeStatus *nodeStatus = [syncManager syncStatusForNodeWithId:node.identifier];
    
    [nodeCell updateCellInfoWithNode:node nodeStatus:nodeStatus];
    BOOL isSyncOn = [syncManager isNodeInSyncList:node];
    
    [nodeCell updateStatusIconsIsSyncNode:isSyncOn isFavoriteNode:NO animate:NO];
    [favoriteManager isNodeFavorite:node session:self.session completionBlock:^(BOOL isFavorite, NSError *error) {
        
        [nodeCell updateStatusIconsIsSyncNode:isSyncOn isFavoriteNode:isFavorite animate:NO];
    }];
    
    if (node.isFolder)
    {
        [nodeCell.image setImage:smallImageForType(@"folder") withFade:NO];
        nodeCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else if (node.isDocument)
    {
        nodeCell.accessoryType = UITableViewCellAccessoryNone;
        
        AlfrescoDocument *document = (AlfrescoDocument *)node;
        ThumbnailManager *thumbnailManager = [ThumbnailManager sharedManager];
        UIImage *thumbnail = [thumbnailManager thumbnailForDocument:document renditionType:kRenditionImageDocLib];
        
        if (thumbnail)
        {
            [nodeCell.image setImage:thumbnail withFade:NO];
        }
        else
        {
            [nodeCell.image setImage:smallImageForType([document.name pathExtension]) withFade:NO];
            [thumbnailManager retrieveImageForDocument:document renditionType:kRenditionImageDocLib session:self.session completionBlock:^(UIImage *image, NSError *error) {
                if (image)
                {
                    AlfrescoNodeCell *updateCell = (AlfrescoNodeCell *)[tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell)
                    {
                        [updateCell.image setImage:image withFade:YES];
                    }
                }
            }];
        }
    }
    
    if ([self.nodePicker isNodeSelected:node])
    {
        [tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    
    return nodeCell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    AlfrescoNode *selectedNode = self.tableViewData[indexPath.row];
    
    if (selectedNode.isFolder)
    {
        BOOL isSyncOn = [[SyncManager sharedManager] isSyncPreferenceOn];
        UIViewController *viewController = nil;
        
        if (isSyncOn)
        {
            viewController = [[NodePickerFavoritesViewController alloc] initWithParentNode:(AlfrescoFolder *)selectedNode session:self.session nodePickerController:self.nodePicker];
            
        }
        else
        {
            viewController = [[NodePickerFileFolderListViewController alloc] initWithFolder:(AlfrescoFolder *)selectedNode
                                                                          folderDisplayName:selectedNode.title
                                                                                    session:self.session
                                                                       nodePickerController:self.nodePicker];
        }
        [self.navigationController pushViewController:viewController animated:YES];
    }
    else
    {
        if (self.nodePicker.type == NodePickerTypeDocuments && self.nodePicker.mode == NodePickerModeSingleSelect)
        {
            [self.nodePicker deselectAllNodes];
            [self.nodePicker selectNode:selectedNode];
            [self.nodePicker pickingNodesComplete];
        }
        else
        {
            [self.nodePicker selectNode:selectedNode];
        }
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    AlfrescoNode *selectedNode = selectedNode = self.tableViewData[indexPath.row];
    
    [self.nodePicker deselectNode:selectedNode];
    [self.tableView reloadData];
}

@end
