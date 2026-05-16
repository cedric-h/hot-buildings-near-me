To run, see `./run.sh`.

### 516 sexy buildings in your area!! 💦

Tired of freezing to death outside? **Want to find hot building floorplans in your area?** Now you can, with a simple command line utility!

Simply provide your latitude and longitude:
```
./main 40.75981272226754, -111.88675301382722
```

The application will find the closest floorplan and write it to a file called `test.svg` in the current working directory.

You can then run `open test.svg` to view it in a web browser.

An easy way to get `lat, lon` pairs is to right click an area in google maps and click the first entry in the context menu.

## Examples

<img src="./screenshots/40.759540447924046, -111.88667436672648.png" height="400">

<img src="./screenshots/40.759540447924046, -111.88667436672648.svg" height="400">

<img src="./screenshots/52.08123200271386, 4.346727684011439.png" height="400">

<img src="./screenshots/52.08123200271386, 4.346727684011439.svg" height="400">


## How this works?
The code is very straightforward and has no compile-time dependencies other than Foundation.

At runtime, it pulls its data from [Source Coop](https://source.coop/), which uses a [Protomaps](https://protomaps.com/) file that's very easy to host on your own using a file store such as S3.

Protomaps stores its data as tiles, which you can fetch using HTTP requests.

These files contain various layers; the layer we care about for this application is the one labeled "Buildings".

We iterate through the features in the Buildings layer and pull out the relevant Geometry.

A single Tile can have hundreds of buildings on it, so it's necessary to sort them by how close they are to the provided longitude and latitude.

The application then takes the closest Building, and transforms its Geometry into an SVG.
