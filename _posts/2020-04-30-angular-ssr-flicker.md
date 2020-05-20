---
title: "Optimizing Observables in Angular Universal (+flickering fix) by Caching with BrowserTransferStateModule"
permalink: "/post/optimizing-observables-in-angular-universal-fixing-content-flickering-by-caching-with-browsertransferstatemodule-5796"
---
#### Disclaimer
If you are simply using `HttpClient` to fetch your data, then you're all set since the solution for duplicate requests and flashing content is simpler and [the official tutorial](https://github.com/angular/universal/blob/master/docs/transfer-http.md) covers it decently well. Hopefully, that does it for you but you are welcome to keep reading if you're interested in handling other scenarios!

## Why
Let's say we have a cooking blog built on Angular Universal where we share our favorite recipes. The blog has a database and we have a service `BlogService` to fetch our content. The code of our post-displaying component looks something like this:
```typescript
import { Component, OnInit } from '@angular/core';
import { BlogService, Post } from './blog-service.service';
import { Observable } from 'rxjs';
@Component({
  selector: 'app-root',
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.css']
})
export class AppComponent implements OnInit {
  blogPost: Observable<Post>;

  constructor(private blogService: BlogService) {
  }
  ngOnInit() {
    const URL_SLUG = 'pasta-cook';
    this.blogPost = this.blogService.getPost(URL_SLUG);
  }
}
```
Pretty simple and totally fine if we have a SPA. But we have an app with SSR and this will pose a few issues.  
When we run the app (with SSR enabled), we'll see the following:  
<div style="text-align: center">
  <video autoplay loop width="500">
      <source src="https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fproblem-demomp4-9383?alt=media&token=ff39f854-2f9c-4a6d-9f76-bc2e788527af"
              type="video/mp4">
      Sorry, your browser doesn't support embedded videos.
  </video>
</div>

Weird, isn't it? We had our content there, but then it disappeared just to appear again later, resulting in a flash on the screen.

Let's look at what's happening there. If we open the Network tab in Chrome Devtools and inspect the initial page request, we can see that page markup comes hydrated with all the content, which is exactly what we want from SSR.  

![hydrated HTML](https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fhydratedhtmlpng-9178?alt=media&token=addf1c51-eebe-450f-a4db-c28b607da1ca)
 
**Note:** In `BlogService` I'm imitating an API and every time there should be a request to the API, I'm logging "Request is made". With a real service, you'd instead look at requests being sent in the Network tab of DevTools.

As we should expect, when we load the page, the server-side makes an API call:

![node logging request](https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fnode-logging-requestpng-9675?alt=media&token=8e740c35-9827-4747-81a5-2f9bd3e85cb4)

But in Chrome's DevTools we see that so does the browser:

![client side logging request](https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fbrowser-logging-requestpng-9674?alt=media&token=d8174e3e-27c7-4f02-8bbb-cac20fa220fd)  

This means that we are making the same request twice and thus putting an additional strain on our data servers by repeatedly fetching the same content.

To summarize, here are the steps that the code performs as we open our page in the browser:  
1. Server fetches the post
2. Server renders the post
3. Browser fetches the same post
4. Browser re-renders the post

The last two steps are unnecessary and they cause the weird screen flashing and duplicate API requests. This happens naturally because with Angular's Server-Side Rendering, the code in your components always runs both on the server and in the browser unless specified otherwise.

## Solution

To fix our problem, we will have to implement server-client caching. Angular's `BrowserTransferStateModule` is exactly what we need to do so.  
In the end, we aim to have the following lifecycle:  
1. Server fetches the post
2. Server saves the post to cache
3. Server renders the post into HTML
4. Browser fetches the post **from cache**

### 0. Setting up
First, we have to import `BrowserTransferStateModule` into `app.module.ts`:
```ts
import { BrowserModule, BrowserTransferStateModule } from '@angular/platform-browser';

imports: [
  BrowserModule.withServerTransition({ appId: 'serverApp' }),
  BrowserTransferStateModule,
  ...
]
```
In `app.server.module.ts` we have to import `ServerTransferStateModule`:
```ts
import { ServerModule, ServerTransferStateModule } from '@angular/platform-server';

imports: [
    AppModule,
    ServerModule,
    ServerTransferStateModule
],
```

In our working component we need to import `TransferState` and `makeStateKey`:
```ts
import { TransferState, makeStateKey } from '@angular/platform-browser';

@Component({
  ...
})
export class AppComponent implements OnInit {
    constructor(private blogService: BlogService, 
                  private state: TransferState) {
    ...
```
### 1. Saving post to cache on the server-side
To implement caching, we will use the `TransferState` service imported earlier. It provides us with a writeable Map (object) with string keys and values of any type. This object gets transferred from server to client.  
To create these state keys, Angular provides `makeStateKey`. Your state keys should carry enough information to later identify the exact service call that we made on the server side. In our case it will be as follows:
```ts
const URL_SLUG = 'pasta-cook';
const dataKey = makeStateKey(`posts/${URL_SLUG}`);
```
Now, let's save our `blogService.getPost(URL_SLUG)` Observable into a variable, so we can transform its values later:
```ts
const $dataSource = this.blogService.getPost(URL_SLUG);
```
When we call `getPost()` on the server-side, we need to save its return value to our state:
```ts
if (isPlatformServer(this.platformId)) {
  this.blogPost = $dataSource.pipe(map(datum => {
    this.state.set(dataKey, datum);
    return datum;
  }), take(1));
}
```
### 2. Reading from state in the browser
When running in the browser, we need to check if `getPost()` was already called on the server and if so, we shouldn't make the call again:
```ts
if (isPlatformServer(this.platformId)) {
  ...
} else if (isPlatformBrowser(this.platformId)) {
  const savedValue = this.state.get(dataKey, null);
  if (savedValue) {
    this.blogPost = $dataSource.pipe(startWith(savedValue), take(1));
  } else {
    this.blogPost = $dataSource;
  }
}
```
The issue is now fixed and only one API request will be made on each page refresh. The annoying content flash is also gone!
### 3. Refactoring and reusing the code
You might say, "that was a ton of code for a single API call!" and I agree with you. The great news is that all of that code can be abstracted away and reused for all Observables. I'm moving the code to `BlogService` (but it's best to move it to a general utils service), where I'll define a `getCachedObservable` function that accepts an Observable and a state key:
```ts
getCachedObservable($dataSource: Observable<any>, dataKey: StateKey<any>) {
  if (isPlatformServer(this.platformId)) {
    return $dataSource.pipe(map(datum => {
      this.state.set(dataKey, datum);
      return datum;
    }), take(1));
  } else if (isPlatformBrowser(this.platformId)) {
    const savedValue = this.state.get(dataKey, null);
    const observableToReturn = savedValue ? $dataSource.pipe(startWith(savedValue), take(1)) : $dataSource;
    return observableToReturn;
  }
}
```
In our components we can simply use that function for any Observable calls:
```ts
this.blogPost = this.blogService.getCachedObservable($dataSource, dataKey);
```
### 4. (optional) Tweaking for other use-cases (i.e. Observable with 2+ values)
In the previous code, we made an assumption that we only care about the first value of our Observable. While it is perfectly fine for our blog with virtually static content, the assumption may not be valid depending on your use-case.  
To see an example, let's suppose our blog article updates every couple of seconds and `getPost()` supplies every update. With the current implementation, we'd only ever see the first value the Observable sent us (because of the `take(1)` operator).  
So let's remove `take(1)` from the logic on the browser side:
```ts
getCachedObservable($dataSource: Observable<any>, dataKey: StateKey<any>) {
  if (isPlatformServer(this.platformId)) {
    ...
  } else if (isPlatformBrowser(this.platformId)) {
    const savedValue = this.state.get(dataKey, null);
    const observableToReturn = savedValue ? $dataSource.pipe(startWith(savedValue)) : $dataSource;
    return observableToReturn;
  }
}
```
Now, if we open the page we'll see the updates:
<div style="text-align: center">
  <video autoplay loop width="500">
      <source src="https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fdisplaying-updatesmp4-0508?alt=media&token=a129191b-3caa-4f4d-a36c-1ad0e01c5520"
              type="video/mp4">
      Sorry, your browser doesn't support embedded videos.
  </video>
</div>

## Bonus - How is state transferred from server to client?
If we look at the page source in the browser, we can see that Angular transfers the state as a JSON string, which it places in a script tag at the bottom of the page and reads on the client-side:  
![page-source-bottom](https://firebasestorage.googleapis.com/v0/b/my-blog-5360d.appspot.com/o/uploads%2Fpage-source-bottompng-9676?alt=media&token=35bae197-9289-4861-89f4-99c9a3d7d586)

## Conclusion
The caching mechanism that I described above can significantly speed up your applications and reduce strain on your servers/computational power. Notice, that while I optimized API service calls, you can optimize any Observables in the same fashion (e.g. you have a library that performs heavy computations and returns an Observable). Lastly, Observables are just a common use-case and you can implement the same mechanism for Promises, synchronous functions, etc.

That's all I have for you today. The full source code of the mini-blog used in the article can be found [here on GitHub](https://github.com/aziz512/angular-ssr-caching-example).  
You are welcome to let me know in the comments if I forgot to cover something or if you have any questions!