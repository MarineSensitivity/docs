
## Icons

- [Material Design Icons](https://fonts.google.com/icons?icon.query=API&icon.set=Material+Icons)
- https://www.flaticon.com

## Convert SVG to PNG for components listing

```bash
in_svg=apps_black_24dp.svg
tmp_png=tmp.png
out_png=apps.png
inkscape -w 150 -h 150 $in_svg -o $tmp_png
convert -gravity Center -background transparent -auto-orient -extent 208x150 $tmp_png $out_png
rm $tmp_png
```

