//
//  FeedbackViewController.swift
//  ProtonMail
//
//  Created by Yanfeng Zhang on 3/11/16.
//  Copyright (c) 2016 ArcTouch. All rights reserved.
//

import Foundation
import Social


protocol FeedbackViewControllerDelegate {
    func dismissed();
}

class FeedbackViewController : ProtonMailViewController, UITableViewDelegate {
    
    private let sectionSource : [FeedbackSection] = [.header, .reviews, .guid]
    private let dataSource : [FeedbackSection : [FeedbackItem]] = [.header : [.header], .reviews : [.rate, .tweet, .facebook], .guid : [.guide, .contact]]
    
    @IBOutlet weak var tableView: UITableView!
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableViewAutomaticDimension;
        tableView.estimatedRowHeight = 36.0
    }
    
    override func viewWillAppear(animated: Bool) {
        
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        if (self.tableView.respondsToSelector("setSeparatorInset:")) {
            self.tableView.separatorInset = UIEdgeInsetsZero
        }
        
        if (self.tableView.respondsToSelector("setLayoutMargins:")) {
            self.tableView.layoutMargins = UIEdgeInsetsZero
        }
    }
    
    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }
    
     /**
    tableview
    
    - parameter tableView:
    
    - returns:
    */
    func numberOfSectionsInTableView(tableView: UITableView!) -> Int  {
        return sectionSource.count
    }
    
    func tableView(tableView: UITableView!, numberOfRowsInSection section: Int) -> Int  {
        let items = dataSource[sectionSource[section]]
        
        return items?.count ?? 0
    }
    
    
    func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let key = sectionSource[section]
        if key.hasTitle {
            let cell: FeedbackHeadCell = tableView.dequeueReusableCellWithIdentifier("feedback_table_section_header_cell") as! FeedbackHeadCell
            cell.configCell(key.title)
            return cell;
        } else {
            return nil
        }
    }
    
    func tableView(tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }
    
    func tableView(tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0.01
    }
    
    func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let key = sectionSource[section]
        if key.hasTitle {
            return 46
        } else {
            return 0.01
        }
    }
    
    func tableView(tableView: UITableView!, cellForRowAtIndexPath indexPath: NSIndexPath!) -> UITableViewCell!  {
        let key = sectionSource[indexPath.section]
        let items : [FeedbackItem]? = dataSource[key]
        if key == .header {
            let cell: UITableViewCell = tableView.dequeueReusableCellWithIdentifier("feedback_table_top_cell", forIndexPath: indexPath) as! UITableViewCell
            cell.selectionStyle = .None
            return cell
        } else {
            let cell: FeedbackTableViewCell = tableView.dequeueReusableCellWithIdentifier("feedback_table_detail_cell", forIndexPath: indexPath) as! FeedbackTableViewCell
            if let item = items?[indexPath.row] {
                cell.configCell(item)
            }
            return cell
        }
    }
    
    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        let key = sectionSource[indexPath.section]
        let items : [FeedbackItem]? = dataSource[key]
        if key == .header {

        } else {
            if let item = items?[indexPath.row] {
                if item == .rate {
                    openRating()
                } else if item == .tweet {
                    shareMore()
                } else if item == .facebook {
                    
                    shareFacebook()
                }
            }
        }
        
        tableView.deselectRowAtIndexPath(indexPath, animated: true)
        self.navigationController?.popToRootViewControllerAnimated(true)
    }
    
    func openRating () {
        let url :NSURL = NSURL(string: "itms-apps://itunes.apple.com/WebObjects/MZStore.woa/wa/viewContentsUserReviews?type=Purple+Software&id=979659905")!
        UIApplication.sharedApplication().openURL(url)
    }
    
    func shareFacebook () {
        if SLComposeViewController.isAvailableForServiceType(SLServiceTypeFacebook) {
            let facebookComposeVC = SLComposeViewController(forServiceType: SLServiceTypeFacebook)
            let url = "https://protonmail.com";
            facebookComposeVC.setInitialText("ProtonMail post .... \(url)")
            
            self.presentViewController(facebookComposeVC, animated: true, completion: nil)
        }
        
    }
    
    func shareMore () {
        
        let bounds = UIScreen.mainScreen().bounds
        UIGraphicsBeginImageContextWithOptions(bounds.size, true, 0.0)
        self.view.drawViewHierarchyInRect(bounds, afterScreenUpdates: false)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let URL = NSURL(string: "http://protonmail.com/")!
        let text = "ProtonMail post default... #ProtonMail \(URL)"
        
        let activityViewController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        
        let iTems = self.extensionContext?.inputItems
        let url = NSURL(string: "https://protonmail.com")!
//        let image = UIImage(named:"trash")!
//        let text : String = "ProtonMail post default";
//        let activityViewController = UIActivityViewController(activityItems: [image, text, url], applicationActivities: nil)
        
        activityViewController.excludedActivityTypes = []
        
        self.presentViewController(activityViewController, animated: true, completion: nil)
        
        
        
        
        
//        NSDictionary *item = @{ AppExtensionVersionNumberKey: VERSION_NUMBER, AppExtensionURLStringKey: URLString };
//        
//        UIActivityViewController *activityViewController = [self activityViewControllerForItem:item viewController:viewController sender:sender typeIdentifier:kUTTypeAppExtensionFindLoginAction];
//        activityViewController.completionWithItemsHandler = ^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
//            if (returnedItems.count == 0) {
//                NSError *error = nil;
//                if (activityError) {
//                    NSLog(@"Failed to findLoginForURLString: %@", activityError);
//                    error = [OnePasswordExtension failedToContactExtensionErrorWithActivityError:activityError];
//                }
//                else {
//                    error = [OnePasswordExtension extensionCancelledByUserError];
//                }
//                
//                if (completion) {
//                    completion(nil, error);
//                }
//                
//                return;
//            }
//            
//            [self processExtensionItem:returnedItems.firstObject completion:^(NSDictionary *itemDictionary, NSError *error) {
//                if (completion) {
//                completion(itemDictionary, error);
//                }
//                }];
//        };
//        
//        [viewController presentViewController:activityViewController animated:YES completion:nil];

    }
    
    func tableView(tableView: UITableView, willDisplayCell cell: UITableViewCell, forRowAtIndexPath indexPath: NSIndexPath) {
        if (cell.respondsToSelector("setSeparatorInset:")) {
            cell.separatorInset = UIEdgeInsetsZero
        }
        
        if (cell.respondsToSelector("setLayoutMargins:")) {
            cell.layoutMargins = UIEdgeInsetsZero
        }
    }
}