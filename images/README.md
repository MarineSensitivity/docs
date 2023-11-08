
## Icons

- [Material Design Icons](https://fonts.google.com/icons?icon.query=API&icon.set=Material+Icons)
- https://www.flaticon.com

## Convert SVG to PNG for components listing



```bash
dir_png=/Users/bbest/Github/MarineSensitivity/docs/images/components
dir_svg=$dir_png/_google-material-icons_svg
# assume square height & width for input svg
svg_hw=100
# possibly different output png dimensions
png_w=200
png_h=200 

tmp_png=$dir_png/tmp.png

# loop through all files in dir_svg
for in_svg in $dir_svg/*.svg; do
  
  # get svg from prefix of input svg
  f=$(basename -- "$in_svg")
  f="${f%-*}"
  out_png=$dir_png/$f.png
  
  # assume square input when converting svg to png
  inkscape -w $svg_hw -h $svg_hw $in_svg -o $tmp_png
  
  # pad the png from square to full width
  convert -gravity Center -background transparent -auto-orient -extent ${png_w}x${png_h} $tmp_png $out_png
  
  # cleanup
  rm $tmp_png
done
```

