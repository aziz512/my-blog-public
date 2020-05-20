JEKYLL_ENV=production jekyll build
cd _site
git init
git remote add origin https://github.com/aziz512/my-blog-public
git checkout -b gh-pages
git add .
git commit -m 'update'
git push -f origin gh-pages