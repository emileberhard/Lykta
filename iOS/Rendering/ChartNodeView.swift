import Charts
import LyktaCore
import SwiftUI

struct ChartNodeView: View {
    let chart: Node.Content.Chart

    var body: some View {
        let view = Chart {
            ForEach(chart.marks.indices, id: \.self) { series in
                MarkContent(mark: chart.marks[series], series: series)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis(chart.axes ? .automatic : .hidden)
        .chartYAxis(chart.axes ? .automatic : .hidden)
        if let range = chart.range {
            view.chartYScale(domain: range)
        } else {
            view
        }
    }
}

private struct MarkContent: ChartContent {
    let mark: Node.Content.Chart.Mark
    let series: Int

    var body: some ChartContent {
        ForEach(mark.values.indices, id: \.self) { index in
            let x = PlottableValue.value("Index", Double(index))
            let y = PlottableValue.value("Value", mark.values[index])
            switch mark.kind {
            case .line:
                LineMark(x: x, y: y, series: .value("Series", series))
                    .interpolationMethod(mark.interpolation.value)
                    .lineStyle(StrokeStyle(lineWidth: mark.lineWidth, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(style(at: index))
            case .area:
                AreaMark(x: x, y: y, series: .value("Series", series), stacking: .unstacked)
                    .interpolationMethod(mark.interpolation.value)
                    .foregroundStyle(style(at: index))
            case .bar:
                RectangleMark(xStart: .value("Index", Double(index) - 0.35), xEnd: .value("Index", Double(index) + 0.35),
                              yStart: .value("Value", 0.0), yEnd: y)
                    .cornerRadius(mark.cornerRadius)
                    .foregroundStyle(style(at: index))
            case .point:
                PointMark(x: x, y: y)
                    .foregroundStyle(style(at: index))
            case .rule:
                RuleMark(y: y)
                    .lineStyle(StrokeStyle(lineWidth: mark.lineWidth, dash: [3, 3]))
                    .foregroundStyle(style(at: index))
            case .sector:
                SectorMark(angle: y, innerRadius: .ratio(mark.innerRadius), angularInset: 1)
                    .foregroundStyle(style(at: index))
            }
        }
    }

    private func style(at index: Int) -> AnyShapeStyle {
        if mark.colors.indices.contains(index) { AnyShapeStyle(mark.colors[index].value) } else { mark.color?.style ?? AnyShapeStyle(.tint) }
    }
}

private extension Node.Content.Chart.Mark.Interpolation {
    var value: InterpolationMethod {
        switch self {
        case .linear: .linear
        case .monotone: .monotone
        case .catmullRom: .catmullRom
        case .cardinal: .cardinal
        case .stepStart: .stepStart
        case .stepCenter: .stepCenter
        case .stepEnd: .stepEnd
        }
    }
}
