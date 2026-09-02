import SwiftUI

struct EditorCanvasView: View {
    @Bindable var model: EditorModel

    @State private var hasActiveInteraction = false
    @State private var hoveredLocation: CGPoint?
    @State private var currentCursor: AnnotationCanvasCursor = .arrow
    @State private var longImageZoom: CGFloat = 1

    private let longImageAspectThreshold: CGFloat = 3
    private let minimumLongImageZoom: CGFloat = 0.25
    private let maximumLongImageZoom: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            if let sourceImage = model.sourceImage {
                let metrics = canvasMetrics(for: sourceImage)

                if metrics.sourceAspectRatio >= longImageAspectThreshold {
                    longImageViewport(
                        sourceImage: sourceImage,
                        metrics: metrics,
                        viewportSize: proxy.size
                    )
                } else {
                    let canvasFrame = aspectFitRect(
                        imageSize: metrics.canvasSize,
                        in: proxy.size
                    )
                    canvasSurface(
                        sourceImage: sourceImage,
                        metrics: metrics,
                        canvasFrame: canvasFrame,
                        containerSize: proxy.size
                    )
                }
            } else {
                ContentUnavailableView("正在载入图片…", systemImage: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            YumYumGlow()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.75)
        )
        .onChange(of: model.imageSize) { _, _ in
            longImageZoom = 1
        }
    }

    private func longImageViewport(
        sourceImage: CGImage,
        metrics: EditorCanvasMetrics,
        viewportSize: CGSize
    ) -> some View {
        let documentPadding: CGFloat = 24
        let availableWidth = max(viewportSize.width - documentPadding * 2, 1)
        let fitWidthScale = min(availableWidth / max(metrics.canvasSize.width, 1), 1)
        let displayScale = fitWidthScale * longImageZoom
        let displaySize = CGSize(
            width: metrics.canvasSize.width * displayScale,
            height: metrics.canvasSize.height * displayScale
        )
        let canvasFrame = CGRect(origin: .zero, size: displaySize)
        let scrollAxes: Axis.Set = longImageZoom > 1.001
            ? [.vertical, .horizontal]
            : .vertical

        return ScrollView(scrollAxes) {
            canvasSurface(
                sourceImage: sourceImage,
                metrics: metrics,
                canvasFrame: canvasFrame,
                containerSize: displaySize
            )
            .padding(documentPadding)
            .frame(
                minWidth: viewportSize.width,
                minHeight: viewportSize.height,
                alignment: .top
            )
        }
        .defaultScrollAnchor(.top)
        .overlay(alignment: .bottomTrailing) {
            longImageZoomControls(metrics: metrics)
                .padding(14)
        }
    }

    private func canvasSurface(
        sourceImage: CGImage,
        metrics: EditorCanvasMetrics,
        canvasFrame: CGRect,
        containerSize: CGSize
    ) -> some View {
        let sourceImageFrame = metrics.sourceImageFrame(in: canvasFrame)
        let baseRadius = model.config.cornerRadius * metrics.shortEdge
        let m = model.config.alignment.cornerMultipliers
        let cornerScale = min(
            canvasFrame.width / max(metrics.canvasSize.width, 1),
            canvasFrame.height / max(metrics.canvasSize.height, 1)
        )
        let viewRadii = (
            tl: baseRadius * m.tl * cornerScale,
            tr: baseRadius * m.tr * cornerScale,
            br: baseRadius * m.br * cornerScale,
            bl: baseRadius * m.bl * cornerScale
        )

        return ZStack(alignment: .topLeading) {
            CanvasBackgroundView(style: model.config.style)
                .frame(width: canvasFrame.width, height: canvasFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .position(x: canvasFrame.midX, y: canvasFrame.midY)

            CanvasScreenshotView(
                image: sourceImage,
                frame: sourceImageFrame,
                cornerRadii: viewRadii,
                shadowStrength: model.config.shadowStrength,
                shortEdge: metrics.shortEdge * cornerScale
            )

            ForEach(model.items) { item in
                AnnotationItemView(
                    item: item,
                    image: model.previewImage ?? NSImage(),
                    sourceImage: model.sourceImage,
                    originalImageSize: model.imageSize,
                    imageFrame: sourceImageFrame,
                    canvasFrame: canvasFrame,
                    isSelected: model.selectedItemIDs.contains(item.id),
                    showsResizeHandles: model.selectionCount == 1,
                    isEditingText: item.id == model.editingTextItemID,
                    allowsRedactionPreviewCaching: !(model.isTransformingExistingAnnotation && model.selectedItemIDs.contains(item.id)),
                    text: Binding(
                        get: { model.text(for: item.id) },
                        set: { model.setText($0, for: item.id) }
                    ),
                    onCommitText: model.commitTextEditing,
                    onTextSizeChange: { size in
                        model.setTextViewContentSize(
                            size,
                            for: item.id,
                            imageFrame: sourceImageFrame,
                            allowedBounds: model.annotationBounds(
                                for: sourceImageFrame,
                                boundaryFrame: canvasFrame
                            )
                        )
                    }
                )
            }
            .allowsHitTesting(!model.isCropping)

            if model.isCropping {
                ImageCropOverlay(
                    cropRect: $model.cropRect,
                    imageSize: sourceImageFrame.size
                )
                .position(x: sourceImageFrame.midX, y: sourceImageFrame.midY)
            } else if model.hasCrop {
                ImageCropPreview(
                    cropRect: model.cropRect,
                    imageSize: sourceImageFrame.size
                )
                .position(x: sourceImageFrame.midX, y: sourceImageFrame.midY)
            }

            if let draftItem = model.draftItem {
                AnnotationItemView(
                    item: draftItem,
                    image: model.previewImage ?? NSImage(),
                    sourceImage: model.sourceImage,
                    originalImageSize: model.imageSize,
                    imageFrame: sourceImageFrame,
                    canvasFrame: canvasFrame,
                    isSelected: false,
                    showsResizeHandles: false,
                    isEditingText: false,
                    allowsRedactionPreviewCaching: false,
                    text: .constant(draftItem.text),
                    onCommitText: {},
                    onTextSizeChange: { _ in }
                )
            }

            if let selectionRect = model.selectionRect {
                let viewSel = viewRect(selectionRect, in: sourceImageFrame)
                AnnotationMarqueeSelectionView()
                    .frame(
                        width: max(viewSel.width, 1),
                        height: max(viewSel.height, 1)
                    )
                    .position(x: viewSel.midX, y: viewSel.midY)
            }
        }
        .frame(
            width: containerSize.width,
            height: containerSize.height,
            alignment: .topLeading
        )
        .contentShape(Rectangle())
        .gesture(interactionGesture(imageFrame: sourceImageFrame, boundaryFrame: canvasFrame))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredLocation = location
                updateCursor(at: location, imageFrame: sourceImageFrame)
            case .ended:
                hoveredLocation = nil
                setCursor(.arrow)
            }
        }
        .onChange(of: model.selectedTool) { _, _ in refreshCursor(imageFrame: sourceImageFrame) }
        .onChange(of: model.itemIDs) { _, _ in refreshCursor(imageFrame: sourceImageFrame) }
        .onChange(of: model.selectedItemIDs) { _, _ in refreshCursor(imageFrame: sourceImageFrame) }
        .onDisappear { setCursor(.arrow) }
    }

    private func longImageZoomControls(metrics: EditorCanvasMetrics) -> some View {
        HStack(spacing: 6) {
            Label("长图", systemImage: "rectangle.portrait.and.arrow.forward")
                .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                .foregroundStyle(RuneTheme.chromeText)

            Text("\(Int(metrics.imageSize.width)) × \(Int(metrics.imageSize.height))")
                .font(RuneFont.mono(size: 10))
                .foregroundStyle(RuneTheme.chromeMuted)
                .monospacedDigit()

            Rectangle()
                .fill(RuneTheme.chromeLine)
                .frame(width: 1, height: 18)

            zoomButton(
                systemImage: "minus",
                label: "缩小长图",
                disabled: longImageZoom <= minimumLongImageZoom + 0.001
            ) {
                longImageZoom = max(minimumLongImageZoom, longImageZoom / 1.25)
            }

            Text("\(Int((longImageZoom * 100).rounded()))%")
                .font(RuneFont.mono(size: 10))
                .foregroundStyle(RuneTheme.chromeText)
                .monospacedDigit()
                .frame(width: 42)

            zoomButton(
                systemImage: "plus",
                label: "放大长图",
                disabled: longImageZoom >= maximumLongImageZoom - 0.001
            ) {
                longImageZoom = min(maximumLongImageZoom, longImageZoom * 1.25)
            }

            Button {
                longImageZoom = 1
            } label: {
                Label("适合宽度", systemImage: "arrow.left.and.right")
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeText)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
            }
            .buttonStyle(.plain)
            .help("恢复适合宽度")
            .accessibilityLabel("恢复长图适合宽度")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .fill(RuneTheme.chromeBase.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                .strokeBorder(RuneTheme.chromeLine, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func zoomButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(RuneFont.swiftUI(size: 10.5, weight: .semibold))
                .foregroundStyle(disabled ? RuneTheme.chromeMuted.opacity(0.45) : RuneTheme.chromeText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                        .fill(Color.white.opacity(disabled ? 0.025 : 0.055))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func canvasMetrics(for sourceImage: CGImage) -> EditorCanvasMetrics {
        let imageSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let shortEdge = min(imageSize.width, imageSize.height)
        let padding = shortEdge * model.config.padding

        var canvasSize = CGSize(
            width: imageSize.width + padding * 2,
            height: imageSize.height + padding * 2
        )
        if let ratio = model.config.aspectRatio.numericValue {
            let currentRatio = canvasSize.width / max(canvasSize.height, 1)
            if currentRatio < ratio {
                canvasSize.width = canvasSize.height * ratio
            } else {
                canvasSize.height = canvasSize.width / ratio
            }
        }

        let horizontalPadding = canvasSize.width - imageSize.width
        let verticalPadding = canvasSize.height - imageSize.height
        return EditorCanvasMetrics(
            imageSize: imageSize,
            canvasSize: canvasSize,
            imageOriginRatio: CGPoint(
                x: model.config.alignment.xFactor * horizontalPadding / max(canvasSize.width, 1),
                y: model.config.alignment.yFactor * verticalPadding / max(canvasSize.height, 1)
            ),
            imageSizeRatio: CGSize(
                width: imageSize.width / max(canvasSize.width, 1),
                height: imageSize.height / max(canvasSize.height, 1)
            ),
            shortEdge: shortEdge
        )
    }

    private func interactionGesture(imageFrame: CGRect, boundaryFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !hasActiveInteraction {
                    hasActiveInteraction = true
                    model.beginInteraction(at: value.startLocation, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                }
                model.updateInteraction(to: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                updateCursor(at: value.location, imageFrame: imageFrame)
            }
            .onEnded { value in
                model.endInteraction(at: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                hasActiveInteraction = false
                updateCursor(at: value.location, imageFrame: imageFrame)
            }
    }

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let padding: CGFloat = 24
        let availableSize = CGSize(width: containerSize.width - padding * 2, height: containerSize.height - padding * 2)
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func viewRect(_ rect: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    private func refreshCursor(imageFrame: CGRect) {
        guard let hoveredLocation else { return }
        updateCursor(at: hoveredLocation, imageFrame: imageFrame)
    }

    private func updateCursor(at location: CGPoint, imageFrame: CGRect) {
        guard model.containsInteractionPoint(location, imageFrame: imageFrame, boundaryFrame: imageFrame) else {
            setCursor(.arrow)
            return
        }

        if hasActiveInteraction {
            setCursor(model.isTransformingExistingAnnotation ? .closedHand : .placement)
        } else if model.hoveredAnnotation(at: location, imageFrame: imageFrame, boundaryFrame: imageFrame) != nil {
            setCursor(.openHand)
        } else if model.selectedTool == .select {
            setCursor(.arrow)
        } else {
            setCursor(.placement)
        }
    }

    private func setCursor(_ cursor: AnnotationCanvasCursor) {
        guard currentCursor != cursor else { return }
        currentCursor = cursor
        cursor.nsCursor.set()
    }
}

private struct EditorCanvasMetrics {
    let imageSize: CGSize
    let canvasSize: CGSize
    let imageOriginRatio: CGPoint
    let imageSizeRatio: CGSize
    let shortEdge: CGFloat

    var sourceAspectRatio: CGFloat {
        imageSize.height / max(imageSize.width, 1)
    }

    func sourceImageFrame(in canvasFrame: CGRect) -> CGRect {
        CGRect(
            x: canvasFrame.minX + imageOriginRatio.x * canvasFrame.width,
            y: canvasFrame.minY + imageOriginRatio.y * canvasFrame.height,
            width: imageSizeRatio.width * canvasFrame.width,
            height: imageSizeRatio.height * canvasFrame.height
        )
    }
}

// MARK: - SwiftUI Background Layer

private struct CanvasBackgroundView: View {
    let style: BackgroundStyle

    var body: some View {
        switch style {
        case .none:
            TransparencyGrid()

        case .solid(let color):
            Rectangle().fill(color.color)

        case .gradient(let preset):
            Rectangle().fill(preset.swiftUIGradient)

        case .wallpaper(let source):
            if let nsImage = NSImage(contentsOfFile: source.path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }

        case .bundledImage(let assetID):
            if let asset = BundledBackgrounds.asset(byID: assetID),
               let nsImage = asset.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
    }
}

// MARK: - Screenshot Layer with Shadow and Rounded Corners

private struct CanvasScreenshotView: View {
    let image: CGImage
    let frame: CGRect
    let cornerRadii: (tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat)
    let shadowStrength: CGFloat
    let shortEdge: CGFloat

    private var clipShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadii.tl,
            bottomLeadingRadius: cornerRadii.bl,
            bottomTrailingRadius: cornerRadii.br,
            topTrailingRadius: cornerRadii.tr,
            style: .continuous
        )
    }

    private var shadowRadius: CGFloat {
        max(2, shortEdge * (0.035 + shadowStrength * 0.035))
    }

    private var shadowOffset: CGFloat {
        shortEdge * (0.012 + shadowStrength * 0.018)
    }

    private var shadowOpacity: Double {
        Double(shadowStrength * 0.36)
    }

    var body: some View {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))

        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .clipShape(clipShape)
            .shadow(
                color: shadowStrength > 0 ? .black.opacity(shadowOpacity) : .clear,
                radius: shadowStrength > 0 ? shadowRadius : 0,
                x: 0,
                y: shadowStrength > 0 ? shadowOffset : 0
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

// MARK: - Supporting Types

private enum AnnotationCanvasCursor: Equatable {
    case arrow
    case placement
    case openHand
    case closedHand

    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .placement: .annotationPlus
        case .openHand: .openHand
        case .closedHand: .closedHand
        }
    }
}

private struct AnnotationMarqueeSelectionView: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.035))
            .overlay {
                Rectangle()
                    .stroke(
                        RuneTheme.spectralGradient,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            }
    }
}

// MARK: - Image Crop Overlay

private struct ImageCropOverlay: View {
    @Binding var cropRect: CGRect
    let imageSize: CGSize

    private let handleSize: CGFloat = 10
    private let minCropFraction: CGFloat = 0.1
    @State private var startRect: CGRect = .zero

    var body: some View {
        Canvas { context, size in
            let crop = pixelRect(in: size)

            var dimPath = Path()
            dimPath.addRect(CGRect(origin: .zero, size: size))
            dimPath.addRect(crop)
            context.fill(dimPath, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

            let border = crop.insetBy(dx: -1, dy: -1)
            context.stroke(Path(border), with: .color(.white), lineWidth: 1.5)

            let dashes: [CGFloat] = [4, 4]
            let thirdW = crop.width / 3
            let thirdH = crop.height / 3
            for i in 1...2 {
                var vLine = Path()
                vLine.move(to: CGPoint(x: crop.minX + thirdW * CGFloat(i), y: crop.minY))
                vLine.addLine(to: CGPoint(x: crop.minX + thirdW * CGFloat(i), y: crop.maxY))
                context.stroke(vLine, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: dashes))

                var hLine = Path()
                hLine.move(to: CGPoint(x: crop.minX, y: crop.minY + thirdH * CGFloat(i)))
                hLine.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + thirdH * CGFloat(i)))
                context.stroke(hLine, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: dashes))
            }
        }
        .allowsHitTesting(false)
        .frame(width: imageSize.width, height: imageSize.height)
        .overlay {
            GeometryReader { geo in
                let size = geo.size
                let crop = pixelRect(in: size)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .gesture(dragGesture(size: size))

                cornerHandle(at: CGPoint(x: crop.minX, y: crop.minY), corner: .topLeft, size: size)
                cornerHandle(at: CGPoint(x: crop.maxX, y: crop.minY), corner: .topRight, size: size)
                cornerHandle(at: CGPoint(x: crop.minX, y: crop.maxY), corner: .bottomLeft, size: size)
                cornerHandle(at: CGPoint(x: crop.maxX, y: crop.maxY), corner: .bottomRight, size: size)

                edgeHandle(at: CGPoint(x: crop.midX, y: crop.minY), edge: .top, size: size)
                edgeHandle(at: CGPoint(x: crop.midX, y: crop.maxY), edge: .bottom, size: size)
                edgeHandle(at: CGPoint(x: crop.minX, y: crop.midY), edge: .left, size: size)
                edgeHandle(at: CGPoint(x: crop.maxX, y: crop.midY), edge: .right, size: size)
            }
            .frame(width: imageSize.width, height: imageSize.height)
        }
    }

    private func pixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: cropRect.origin.x * size.width,
            y: cropRect.origin.y * size.height,
            width: cropRect.width * size.width,
            height: cropRect.height * size.height
        )
    }

    private func cornerHandle(at point: CGPoint, corner: CropCorner, size: CGSize) -> some View {
        Circle()
            .fill(.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let nx = value.location.x / size.width
                        let ny = value.location.y / size.height
                        var r = cropRect
                        switch corner {
                        case .topLeft:
                            let newX = min(nx, r.maxX - minCropFraction)
                            let newY = min(ny, r.maxY - minCropFraction)
                            r.size.width += r.origin.x - max(0, newX)
                            r.size.height += r.origin.y - max(0, newY)
                            r.origin.x = max(0, newX)
                            r.origin.y = max(0, newY)
                        case .topRight:
                            r.size.width = max(minCropFraction, min(1 - r.origin.x, nx - r.origin.x))
                            let newY = min(ny, r.maxY - minCropFraction)
                            r.size.height += r.origin.y - max(0, newY)
                            r.origin.y = max(0, newY)
                        case .bottomLeft:
                            let newX = min(nx, r.maxX - minCropFraction)
                            r.size.width += r.origin.x - max(0, newX)
                            r.origin.x = max(0, newX)
                            r.size.height = max(minCropFraction, min(1 - r.origin.y, ny - r.origin.y))
                        case .bottomRight:
                            r.size.width = max(minCropFraction, min(1 - r.origin.x, nx - r.origin.x))
                            r.size.height = max(minCropFraction, min(1 - r.origin.y, ny - r.origin.y))
                        }
                        cropRect = r
                    }
            )
    }

    private func edgeHandle(at point: CGPoint, edge: CropEdge, size: CGSize) -> some View {
        Capsule()
            .fill(.white)
            .frame(
                width: edge == .top || edge == .bottom ? 24 : 6,
                height: edge == .left || edge == .right ? 24 : 6
            )
            .shadow(color: .black.opacity(0.3), radius: 2)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let nx = value.location.x / size.width
                        let ny = value.location.y / size.height
                        var r = cropRect
                        switch edge {
                        case .top:
                            let newY = min(ny, r.maxY - minCropFraction)
                            r.size.height += r.origin.y - max(0, newY)
                            r.origin.y = max(0, newY)
                        case .bottom:
                            r.size.height = max(minCropFraction, min(1 - r.origin.y, ny - r.origin.y))
                        case .left:
                            let newX = min(nx, r.maxX - minCropFraction)
                            r.size.width += r.origin.x - max(0, newX)
                            r.origin.x = max(0, newX)
                        case .right:
                            r.size.width = max(minCropFraction, min(1 - r.origin.x, nx - r.origin.x))
                        }
                        cropRect = r
                    }
            )
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if startRect == .zero { startRect = cropRect }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var r = startRect
                r.origin.x = max(0, min(1 - r.width, startRect.origin.x + dx))
                r.origin.y = max(0, min(1 - r.height, startRect.origin.y + dy))
                cropRect = r
            }
            .onEnded { _ in startRect = .zero }
    }

    private enum CropCorner { case topLeft, topRight, bottomLeft, bottomRight }
    private enum CropEdge { case top, bottom, left, right }
}

// MARK: - Crop Preview (non-interactive, shows active crop)

private struct ImageCropPreview: View {
    let cropRect: CGRect
    let imageSize: CGSize

    var body: some View {
        Canvas { context, size in
            let crop = CGRect(
                x: cropRect.origin.x * size.width,
                y: cropRect.origin.y * size.height,
                width: cropRect.width * size.width,
                height: cropRect.height * size.height
            )

            var dimPath = Path()
            dimPath.addRect(CGRect(origin: .zero, size: size))
            dimPath.addRect(crop)
            context.fill(dimPath, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

            let border = crop.insetBy(dx: -1, dy: -1)
            context.stroke(Path(border), with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .frame(width: imageSize.width, height: imageSize.height)
    }
}

struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let cellSize: CGFloat = 10
            let rows = Int(ceil(size.height / cellSize))
            let cols = Int(ceil(size.width / cellSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    let isLight = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? Color.white : Color(white: 0.88))
                    )
                }
            }
        }
        .drawingGroup()
    }
}
